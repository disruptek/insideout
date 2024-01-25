import std/atomics
import std/hashes
import std/locks
import std/posix
import std/strutils

import pkg/cps
from pkg/cps/spec import cpsStackFrames

import insideout/atomic/flags
import insideout/atomic/refs
export refs

import insideout/mailboxes
import insideout/threads
import insideout/eventqueue

const
  insideoutStackSize* {.intdefine.} = 16_384
  insideoutRenameThread* {.booldefine.} = true

type
  InsideError* = object of OSError
  SpawnError* = object of InsideError
  Dispatcher* = proc(p: pointer): pointer {.noconv.}
  Factory[A, B] = proc(mailbox: UnboundedFifo[B]) {.cps: A.}

  RuntimeFlag* = enum
    Frozen
    NotFrozen
    Halted
    NotHalted
    Reaped
    NotReaped

  RuntimeState* = enum
    Uninitialized
    Launching
    Running
    Stopping
    Stopped

type
  FlagT = uint32
  RuntimeObj[A, B] = object
    handle: PThread
    status: Atomic[RuntimeState]
    flags: AtomicFlags[FlagT]
    events: Fd
    signals: Fd
    factory: Factory[A, B]
    mailbox: UnboundedFifo[B]
    continuation: A
    error: ref Exception

  Runtime*[A, B] {.requiresInit.} = AtomicRef[RuntimeObj[A, B]]

proc `=copy`*[A, B](runtime: var RuntimeObj[A, B]; other: RuntimeObj[A, B]) {.error.} =
  ## copies are denied
  discard

proc state[A, B](runtime: var RuntimeObj[A, B]): RuntimeState =
  load(runtime.status, order = moAcquire)

when defined(danger):
  template assertInitialized*(runtime: Runtime): untyped = discard
else:
  proc assertInitialized*(runtime: Runtime) =
    ## raise a Defect if the runtime is not initialized
    if unlikely runtime.isNil:
      raise AssertionDefect.newException "runtime uninitialized"

proc setState(runtime: var RuntimeObj; value: RuntimeState) =
  var prior: RuntimeState = Uninitialized
  while prior < value:
    if compareExchange(runtime.status, prior, value,
                       order = moSequentiallyConsistent):
      break

proc state*[A, B](runtime: Runtime[A, B]): RuntimeState =
  assertInitialized runtime
  state(runtime[])

proc ran*[A, B](runtime: Runtime[A, B]): bool {.deprecated.} =
  ## true if the runtime has run
  assertInitialized runtime
  runtime.state >= Launching

proc hash*(runtime: Runtime): Hash =
  ## whatfer inclusion in a table, etc.
  assertInitialized runtime
  cast[Hash](runtime[].handle)

proc `$`(thread: PThread or SysThread): string =
  thread.hash.uint32.toHex()

proc `$`(runtime: RuntimeObj): string =
  $(cast[uint](runtime.handle).toHex())

proc `$`*(runtime: Runtime): string =
  assertInitialized runtime
  result = "<run:"
  result.add $runtime[]
  result.add "-"
  result.add $runtime.state
  result.add ">"

proc `==`*(a, b: Runtime): bool =
  mixin hash
  assertInitialized a
  assertInitialized b
  hash(a) == hash(b)

proc cancel[A, B](runtime: var RuntimeObj[A, B]): bool =
  ## cancel a runtime; true if successful,
  ## false if the runtime is not running
  case runtime.state
  of Uninitialized, Stopped:
    false
  else:
    runtime.setState(Stopping)
    0 == pthread_cancel(runtime.handle)

proc signal[A, B](runtime: var RuntimeObj[A, B]; sig: int): bool {.used.} =
  ## send a signal to a runtime; true if successful
  if runtime.state in {Launching, Running, Stopping}:
    result = 0 == pthread_kill(runtime.handle, sig.cint)

proc kill[A, B](runtime: var RuntimeObj[A, B]): bool {.used.} =
  ## kill a runtime; false if the runtime is not running
  signal(runtime, 9)

proc stop*[A, B](runtime: Runtime[A, B]) =
  ## gently ask the runtime to exit
  assertInitialized runtime
  case state(runtime[])
  of Uninitialized, Stopping, Stopped:
    discard
  else:
    runtime[].setState(Stopping)

proc join*[A, B](runtime: Runtime[A, B]) =
  ## block until the runtime has exited
  assertInitialized runtime
  while true:
    let current: FlagT = getFlags(runtime[].flags)
    let flags: set[RuntimeFlag] = toFlags[FlagT, RuntimeFlag](current)
    if {Reaped, Halted} * flags == {Reaped, Halted}:
      break
    else:
      checkWait waitMask(runtime[].flags, current, {Reaped, Halted})

proc cancel*[A, B](runtime: Runtime[A, B]): bool {.discardable.} =
  ## cancel a runtime; true if successful.
  ## always succeeds if the runtime is not running.
  assertInitialized runtime
  result = cancel runtime[]

template assertReady(runtime: RuntimeObj): untyped =
  when not defined(danger):  # if this isn't dangerous, i don't know what is
    if runtime.mailbox.isNil:
      raise ValueError.newException "nil mailbox"
    elif runtime.factory.fn.isNil:
      raise ValueError.newException "nil factory function"
    elif runtime.state != Uninitialized:
      raise ValueError.newException "already launched"

proc renderError(e: ref Exception): string =
  result.add e.name
  result.add ": "
  result.add e.msg

proc bounce*[T: Continuation](c: sink T): T =
  var c: Continuation = move c
  var fn = c.fn
  result = T fn(move c)

type
  ContinuationFn = proc (c: sink Continuation): Continuation {.nimcall.}

proc teardown[A, B](p: pointer) {.noconv.} =
  block:
    var runtime = cast[Runtime[A, B]](p)
    if not runtime[].continuation.isNil:
      if not runtime[].continuation.mom.isNil:
        reset runtime[].continuation.mom
      reset runtime[].continuation
    if not runtime[].mailbox.isNil:
      reset runtime[].mailbox
    runtime[].setState(Stopped)
    runtime[].flags.toggle(NotHalted, Halted)
    runtime[].flags.toggle(NotReaped, Reaped)
    wakeMask(runtime[].flags, {Halted, Reaped})
    # we won't get another chance to properly
    # decrement the rc on the runtime
    forget runtime
  when defined(gcOrc):
    GC_runOrc()

proc chill[A, B](runtime: var RuntimeObj[A, B]): cint =
  var prior: cint
  result =
    pthread_setcancelstate(PTHREAD_CANCEL_ENABLE.cint, addr prior)
  pthread_testcancel()
  when true:
    # wait on flags
    let current = getFlags(runtime.flags)
    let flags = toFlags[FlagT, RuntimeFlag](current)
    if Frozen in flags:
      checkWait waitMask(runtime.flags, current, {NotFrozen})
      result =
        pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)
  else:
    # wait for an interrupt
    if 0 == sleep(10):
      runtime[].setState(Stopped)
    else:
      result =
        pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)

proc dispatcher[A, B](runtime: sink Runtime[A, B]) =
  ## blocking dispatcher for a runtime.
  ##
  ## uses the factory to instantiate a continuation,
  ## then runs it with the mailbox as input.
  ##
  ## the continuation is expected to yield in the event
  ## that the mailbox is unexpectedly unavailable.  any
  ## thread interruptions similarly return control to
  ## the dispatcher.
  var result: cint = 0  # XXX temporary
  pthread_cleanup_push(teardown[A, B], runtime.address)

  block:
    var phase = 0
    while true:
      case runtime.state
      of Uninitialized:
        raise Defect.newException:
          "dispatched runtime is uninitialized"
      of Launching:
        var prior: cint
        case phase
        of 0:
          result =
            pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)
        of 1:
          result =
            pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED.cint, addr prior)
        of 2:
          when insideoutRenameThread:
            result =
              pthread_setname_np(runtime[].handle, $A)
        else:
          runtime[].setState(Running)
        if result == 0:
          inc phase
        else:
          runtime[].setState(Stopping)
      of Running:
        if Frozen in toFlags[FlagT, RuntimeFlag](runtime[].flags):
          result = chill runtime[]
        else:
          if dismissed runtime[].continuation:
            # instantiate continuation to consume mailbox
            runtime[].continuation = runtime[].factory.call(runtime[].mailbox)
          # check for a bogus factory composition
          if dismissed runtime[].continuation:
            runtime[].setState(Stopping)
          else:
            try:
              var fn: ContinuationFn = runtime[].continuation.fn
              var temporary: Continuation = fn(move runtime[].continuation)
              runtime[].continuation = A temporary
              if not runtime[].continuation.running:
                runtime[].setState(Stopping)
            except CatchableError as e:
              when compileOption"stackTrace":
                writeStackTrace()
              stdmsg().writeLine:
                renderError e
              result = errno
              runtime[].setState(Stopping)
      of Stopping:
        break
      of Stopped:
        raise Defect.newException "how did we get here?"

  pthread_exit(addr result)
  pthread_cleanup_pop(0)

proc thread[A, B](p: pointer): pointer {.noconv.} =
  ## thread-local continuation dispatch
  var runtime = cast[Runtime[A, B]](p)
  runtime.dispatcher()

template spawnCheck(errno: cint): untyped =
  let e = errno
  if e != 0:
    raise SpawnError.newException: $strerror(errno)

proc spawn[A, B](runtime: var RuntimeObj[A, B]; factory: Factory[A, B]; mailbox: UnboundedFifo[B]) =
  ## add compute to mailbox
  runtime.factory = factory
  runtime.mailbox = mailbox
  store(runtime.flags,
        toFlags[FlagT, RuntimeFlag]({NotHalted, NotReaped, NotFrozen}),
        order = moSequentiallyConsistent)
  assertReady runtime
  var attr {.noinit.}: PThreadAttr
  spawnCheck pthread_attr_init(addr attr)
  spawnCheck pthread_attr_setdetachstate(addr attr,
                                         PTHREAD_CREATE_DETACHED.cint)
  spawnCheck pthread_attr_setstacksize(addr attr, insideoutStackSize.cint)

  # i guess this is really happening...
  runtime.setState(Launching)
  spawnCheck pthread_create(addr runtime.handle, addr attr,
                            thread[A, B], cast[pointer](addr runtime))
  spawnCheck pthread_attr_destroy(addr attr)

proc spawn*[A, B](factory: Factory[A, B]; mailbox: UnboundedFifo[B]): Runtime[A, B] =
  ## create compute from a factory and mailbox
  new result
  spawn(result[], factory, mailbox)

proc clone*[A, B](runtime: Runtime[A, B]): Runtime[A, B] =
  ## clone a `runtime` to perform the same work
  assertInitialized runtime
  assertReady runtime[]
  new result
  spawn(result[], runtime[].factory, runtime[].mailbox)

proc factory*[A, B](runtime: Runtime[A, B]): Factory[A, B] =
  ## recover the factory from the runtime
  assertInitialized runtime
  runtime[].factory

proc mailbox*[A, B](runtime: Runtime[A, B]): UnboundedFifo[B] =
  ## recover the mailbox from the runtime
  assertInitialized runtime
  runtime[].mailbox

proc pinToCpu*[A, B](runtime: Runtime[A, B]; cpu: Natural) =
  ## assign a runtime to a specific cpu index
  assertInitialized runtime
  if state(runtime[]) >= Launching:
    pinToCpu(runtime[].handle, cpu)
  else:
    raise ValueError.newException "runtime unready to pin"

proc handle*[A, B](runtime: Runtime[A, B]): PThread =
  assertInitialized runtime
  runtime[].handle

proc flags*[A, B](runtime: Runtime[A, B]): set[RuntimeFlag] =
  ## recover the flags from the runtime
  assertInitialized runtime
  toFlags[FlagT, RuntimeFlag](runtime[].flags)

proc pause*[A, B](runtime: Runtime[A, B]) =
  ## pause a running runtime
  assertInitialized runtime
  case state(runtime[])
  of Running:
    if toggle(runtime[].flags, NotFrozen, Frozen):
      wakeMask(runtime[].flags, {Frozen})
  else:
    discard

proc resume*[A, B](runtime: Runtime[A, B]) =
  ## resume a running runtime
  assertInitialized runtime
  case state(runtime[])
  of Running:
    if toggle(runtime[].flags, Frozen, NotFrozen):
      wakeMask(runtime[].flags, {NotFrozen})
  else:
    discard

proc halt*[A, B](runtime: Runtime[A, B]) =
  ## halt a running runtime
  assertInitialized runtime
  case state(runtime[])
  of Running:
    if toggle(runtime[].flags, NotHalted, Halted):
      wakeMask(runtime[].flags, {Halted})
  else:
    discard
