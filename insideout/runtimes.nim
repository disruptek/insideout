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
#import insideout/eventqueue

const
  insideoutStackSize* {.intdefine.} = 16_384
  insideoutRenameThread* {.booldefine.} = true

type
  InsideError* = object of OSError
  SpawnError* = object of InsideError
  Dispatcher* = proc(p: pointer): pointer {.noconv.}
  Factory*[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

  RuntimeFlag* {.size: 2.} = enum
    Frozen
    Halted
    Reaped

  RuntimeState* = enum
    Uninitialized
    Launching
    Running
    Stopping
    Stopped

type
  RuntimeObj[A, B] = object
    handle: PThread
    status: Atomic[RuntimeState]
    flags: AtomicFlags32
    #events: Fd
    #signals: Fd
    factory: Factory[A, B]
    mailbox: Mailbox[B]
    continuation: A
    error: ref Exception

  Runtime*[A, B] = AtomicRef[RuntimeObj[A, B]]

proc `=copy`*[A, B](runtime: var RuntimeObj[A, B]; other: RuntimeObj[A, B]) {.error.} =
  ## copies are denied
  discard

proc state[A, B](runtime: var RuntimeObj[A, B]): RuntimeState =
  load(runtime.status, order = moAcquire)

proc setState(runtime: var RuntimeObj; value: RuntimeState) =
  var prior: RuntimeState = Uninitialized
  while prior < value:
    if compareExchange(runtime.status, prior, value,
                       order = moSequentiallyConsistent):
      break

proc state*[A, B](runtime: Runtime[A, B]): RuntimeState =
  assert not runtime.isNil
  state(runtime[])

proc hash*(runtime: Runtime): Hash =
  ## whatfer inclusion in a table, etc.
  assert not runtime.isNil
  cast[Hash](runtime[].handle)

proc `$`(thread: PThread or SysThread): string =
  thread.hash.uint32.toHex()

proc `$`(runtime: RuntimeObj): string =
  $(cast[uint](runtime.handle).toHex())

proc `$`*(runtime: Runtime): string =
  assert not runtime.isNil
  result = "<run:"
  result.add $runtime[]
  result.add "-"
  result.add $runtime.state
  result.add ">"

proc `==`*(a, b: Runtime): bool =
  mixin hash
  assert not a.isNil
  assert not b.isNil
  hash(a) == hash(b)

proc cancel[A, B](runtime: var RuntimeObj[A, B]): bool =
  ## cancel a runtime; true if successful,
  ## false if the runtime is not running
  while true:
    case runtime.state
    of Uninitialized, Stopped:
      return false
    of Launching:
      discard       # FIXME: would be nice to remove this spin
    else:
      runtime.setState(Stopping)
      return 0 == pthread_cancel(runtime.handle)

proc signal[A, B](runtime: var RuntimeObj[A, B]; sig: int): bool {.used.} =
  ## send a signal to a runtime; true if successful
  if runtime.state in {Launching, Running, Stopping}:
    result = 0 == pthread_kill(runtime.handle, sig.cint)

proc kill[A, B](runtime: var RuntimeObj[A, B]): bool {.used.} =
  ## kill a runtime; false if the runtime is not running
  signal(runtime, 9)

proc stop*[A, B](runtime: Runtime[A, B]) =
  ## gently ask the runtime to exit
  assert not runtime.isNil
  case state(runtime[])
  of Uninitialized, Stopping, Stopped:
    discard
  else:
    runtime[].setState(Stopping)

proc join*[A, B](runtime: sink Runtime[A, B]) {.raises: ValueError.} =
  ## block until the runtime has exited
  assert not runtime.isNil
  while true:  # FIXME: rm spin
    let flags = load(runtime[].flags, order = moSequentiallyConsistent)
    if flags && <<{Reaped, Halted}:
      break
    else:
      checkWait waitMask(runtime[].flags, flags, <<{Reaped, Halted})

proc cancel*[A, B](runtime: Runtime[A, B]): bool {.discardable.} =
  ## cancel a runtime; true if successful.
  ## always succeeds if the runtime is not running.
  assert not runtime.isNil
  result = cancel runtime[]

template assertReady(runtime: RuntimeObj): untyped =
  when not defined(danger):  # if this isn't dangerous, i don't know what is
    if runtime.mailbox.isNil:
      raise ValueError.newException "nil mailbox"
    elif runtime.factory.fn.isNil:
      raise ValueError.newException "nil factory function"
    elif runtime.state != Uninitialized:
      raise ValueError.newException "already launched"

proc renderError(e: ref Exception; s = "crash;"): string =
  result = newStringOfCap(16 + s.len + e.name.len + e.msg.len)
  result.add "#"
  result.add $getThreadId()
  result.add " "
  result.add s
  result.add " "
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
  const cErrorMsg = "destroying " & $A & " continuation;"
  const mErrorMsg = "discarding " & $B & " mailbox;"
  block:
    var runtime = cast[Runtime[A, B]](p)
    runtime[].flags.enable Halted
    try:
      reset runtime[].continuation
    except CatchableError as e:
      stdmsg().writeLine:
        renderError(e, cErrorMsg)
    try:
      reset runtime[].mailbox
    except CatchableError as e:
      stdmsg().writeLine:
        renderError(e, mErrorMsg)
    runtime[].setState(Stopped)
    runtime[].flags.enable Reaped
    wakeMask(runtime[].flags, <<{Reaped, Halted})
    # we won't get another chance to properly
    # decrement the rc on the runtime
    forget runtime
  when defined(gcOrc):
    GC_runOrc()

when false:
  template mayCancel(r: typed; body: typed): untyped =
    var prior: cint
    r = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE.cint, addr prior)
    try:
      body
    finally:
      r = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)

proc chill[A, B](runtime: var RuntimeObj[A, B]): cint =
  # wait on flags
  let flags = load(runtime.flags, order = moSequentiallyConsistent)
  if flags && <<Frozen:
    checkWait waitMask(runtime.flags, flags, <<Frozen)
  when false:
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
  const cErrorMsg = $A & " dispatcher crash;"
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
          result = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)
          discard
        of 1:
          result = pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED.cint, addr prior)
          discard
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
        if <<Frozen in runtime[].flags:
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
                renderError(e, cErrorMsg)
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
    raise SpawnError.newException: $strerror(e)

proc spawn[A, B](runtime: var RuntimeObj[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
  ## add compute to mailbox
  runtime.factory = factory
  runtime.mailbox = mailbox
  store(runtime.flags, <<!{Halted, Reaped, Frozen},
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

proc spawn*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]): Runtime[A, B] =
  ## create compute from a factory and mailbox
  new result
  spawn(result[], factory, mailbox)

proc clone*[A, B](runtime: Runtime[A, B]): Runtime[A, B] =
  ## clone a `runtime` to perform the same work
  assert not runtime.isNil
  new result
  spawn(result[], runtime[].factory, runtime[].mailbox)

proc factory*[A, B](runtime: Runtime[A, B]): Factory[A, B] =
  ## recover the factory from the runtime
  assert not runtime.isNil
  runtime[].factory

proc mailbox*[A, B](runtime: Runtime[A, B]): Mailbox[B] =
  ## recover the mailbox from the runtime
  assert not runtime.isNil
  runtime[].mailbox

proc pinToCpu*[A, B](runtime: Runtime[A, B]; cpu: Natural) =
  ## assign a runtime to a specific cpu index
  assert not runtime.isNil
  if state(runtime[]) >= Launching:
    pinToCpu(runtime[].handle, cpu)
  else:
    raise ValueError.newException "runtime unready to pin"

proc handle*[A, B](runtime: Runtime[A, B]): PThread =
  assert not runtime.isNil
  runtime[].handle

proc pause*[A, B](runtime: Runtime[A, B]) =
  ## pause a running runtime
  assert not runtime.isNil
  case state(runtime[])
  of Running:
    if runtime[].flags.enable Frozen:
      wakeMask(runtime[].flags, <<Frozen)
  else:
    discard

proc resume*[A, B](runtime: Runtime[A, B]) =
  ## resume a running runtime
  assert not runtime.isNil
  case state(runtime[])
  of Running:
    if runtime[].flags.disable Frozen:
      wakeMask(runtime[].flags, <<!Frozen)
  else:
    discard

proc halt*[A, B](runtime: Runtime[A, B]) =
  ## halt a running runtime
  assert not runtime.isNil
  case state(runtime[])
  of Running:
    if runtime[].flags.enable Halted:
      wakeMask(runtime[].flags, <<Halted)
  else:
    discard
