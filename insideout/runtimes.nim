import std/atomics
import std/hashes
import std/locks
import std/posix
import std/strutils

import pkg/cps
from pkg/cps/spec import cpsStackFrames

import insideout/atomic/refs
export refs

import insideout/mailboxes
import insideout/monkeys
import insideout/semaphores
import insideout/threads

const
  insideoutDetached* {.booldefine.} = false
  insideoutCancels* {.booldefine.} = false
  insideoutStackSize* {.intdefine.} = 32_768

type
  Dispatcher* = proc(p: pointer): pointer {.noconv.}
  Factory[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

  RuntimeState* = enum
    Uninitialized
    Launching
    Running
    Stopping
    Stopped

when insideoutNimThreads:
  type
    RuntimeObj[A, B] = object
      thread: Thread[Runtime[A, B]]
      factory: Factory[A, B]
      mailbox: Mailbox[B]
      status: Atomic[RuntimeState]
      changed: Cond
      changer: Lock
      result: cint

    Runtime*[A, B] = AtomicRef[RuntimeObj[A, B]]

  template handle(runtime: RuntimeObj): untyped =
      cast[PThread](runtime.thread.handle)
else:
  type
    RuntimeObj[A, B] = object
      handle: PThread
      factory: Factory[A, B]
      mailbox: Mailbox[B]
      status: Atomic[RuntimeState]
      changed: Cond
      changer: Lock
      result: cint

    Runtime*[A, B] = AtomicRef[RuntimeObj[A, B]]

proc runtime[A, B](runtime: var RuntimeObj[A, B]): Runtime[A, B] =
  ## recover the Runtime from the RuntimeObj
  cast[Runtime[A, B]](addr runtime)

proc `=copy`*[A, B](runtime: var RuntimeObj[A, B]; other: RuntimeObj[A, B]) {.error.} =
  ## copies are denied
  discard

proc state(runtime: var RuntimeObj): RuntimeState =
  sleepyMonkey()
  load(runtime.status)

proc setState(runtime: var RuntimeObj; value: RuntimeState) =
  case value
  of Uninitialized:
    raise ValueError.newException:
      "attempt to assign Uninitialized state"
  else:
    var prior: RuntimeState = Uninitialized
    while prior < value:
      sleepyMonkey()
      if compareExchange(runtime.status, prior, value,
                         order = moSequentiallyConsistent):
        sleepyMonkey()
        withLock runtime.changer:
          broadcast runtime.changed
        break

proc state*(runtime: Runtime): RuntimeState =
  if runtime.isNil:
    Uninitialized
  else:
    runtime[].state

proc wait(runtime: var RuntimeObj): RuntimeState =
  withLock runtime.changer:
    wait(runtime.changed, runtime.changer)
    result = runtime.state

proc wait*(runtime: Runtime): RuntimeState =
  ## wait for the state to change
  result = runtime.state
  if result notin {Uninitialized, Stopped}:
    result = wait runtime[]

proc ran*[A, B](runtime: Runtime[A, B]): bool =
  ## true if the runtime has run
  runtime.state >= Launching

proc hash*(runtime: Runtime): Hash =
  ## whatfer inclusion in a table, etc.
  when false:
    mixin address
    hash cast[int](address runtime)
  else:
    case runtime.state
    of Uninitialized:
      raise ValueError.newException "runtime is uninitialized"
    else:
      cast[Hash](runtime[].handle)

proc `$`(thread: PThread or SysThread): string =
  # safe on linux at least
  thread.uint.toHex()

proc `$`(runtime: RuntimeObj): string =
  $(cast[uint](runtime.handle).toHex())

proc `$`*(runtime: Runtime): string =
  case runtime.state
  of Uninitialized:
    result = "<unruntime>"
  else:
    result = "<run:"
    result.add $runtime[]
    result.add "-"
    result.add $runtime.state
    result.add ">"

proc `==`*(a, b: Runtime): bool =
  mixin hash
  hash(a) == hash(b)

proc join[A, B](runtime: var RuntimeObj[A, B]): int {.inline.} =
  while true:
    case runtime.state
    of Uninitialized:
      raise ValueError.newException:
        "attempt to join uninitialized runtime"
    of Launching:
      discard wait runtime
    of Running:
      when insideoutDetached:
        runtime.setState(Stopping)
      else:
        withLock runtime.changer:
          when B is ref or B is ptr:
            runtime.mailbox.send nil.B
          if runtime.state == Running:
            wait(runtime.changed, runtime.changer)
    of Stopping:
      when insideoutDetached:
        withLock runtime.changer:
          if runtime.state == Stopping:
            wait(runtime.changed, runtime.changer)
      else:
        var value = cast[pointer](addr runtime.result)  # var for nim-1.6
        result = pthread_join(runtime.handle, addr value)
        runtime.setState(Stopped)
    of Stopped:
      break

proc join*(runtime: Runtime): int {.discardable, inline.} =
  ## join a runtime thread; raises if the runtime is Uninitialized,
  ## spins while the runtime is Launching, and returns immediately
  ## if the runtime is Stopped.  otherwise, returns the result of
  ## pthread_join() while assigning the return value of the runtime.
  discard join runtime[]

when insideoutCancels:
  proc quit[A, B](runtime: var RuntimeObj[A, B]) =
    ## gently ask the runtime to exit
    case runtime.state
    of Uninitialized, Stopping, Stopped:
      discard
    else:
      runtime.setState(Stopping)

  proc cancel[A, B](runtime: var RuntimeObj[A, B]): bool =
    ## cancel a runtime; true if the runtime is not running
    case runtime.state
    of Uninitialized, Stopped:
      result = true
    else:
      result = 0 == pthread_cancel(runtime.handle)
      if result:
        runtime.setState(Stopped)

  proc signal[A, B](runtime: var RuntimeObj[A, B]; sig: int): bool =
    ## send a signal to a runtime; true if successful
    if runtime.state in {Launching, Running, Stopping}:
      result = 0 == pthread_kill(runtime.handle, sig.cint)

  proc kill[A, B](runtime: var RuntimeObj[A, B]): bool =
    ## kill a runtime; true if the runtime is not running
    result = runtime.state notin {Launching, Running, Stopping}
    if not result:
      result = signal(runtime, 9)
      if result:
        runtime.setState(Stopped)
else:
  proc quit[A, B](runtime: var RuntimeObj[A, B]) =
    ## gently ask the runtime to exit
    case runtime.state
    of Uninitialized, Stopped:
      discard
    of Stopping:
      # XXX: temporary to work around possible race;
      #      remove once we have a non-blocking recv
      #      (or detached threads)
      when B is ref or B is ptr:
        runtime.mailbox.send nil.B
      discard join runtime
    else:
      when B is ref or B is ptr:
        runtime.mailbox.send nil.B
      discard join runtime

  proc cancel[A, B](runtime: var RuntimeObj[A, B]): bool =
    quit runtime

  proc kill[A, B](runtime: var RuntimeObj[A, B]): bool =
    quit runtime

proc quit*[A, B](runtime: Runtime[A, B]) =
  ## gently ask the runtime to exit
  if not runtime.isNil:
    quit runtime[]

when false:
  proc shutdown[A, B](runtime: var RuntimeObj[A, B]) =
    while true:
      case runtime.state
      of Uninitialized, Stopped:
        break
      of Running:
        runtime.setState(Stopping)
      of Stopping:
        when false:
          if not cancel runtime:
            # XXX: lost thread?
            runtime.setState(Stopped)

proc `=destroy`*[A, B](runtime: var RuntimeObj[A, B]) =
  ## ensure the runtime has stopped before it is destroyed
  mixin `=destroy`
  if runtime.state != Uninitialized:
    discard join runtime
    # XXX: ideally, the client must hold a ref to listen to the changer
    withLock runtime.changer:
      broadcast runtime.changed
    deinitLock runtime.changer
    deinitCond runtime.changed
  reset runtime.mailbox
  when insideoutNimThreads:
    `=destroy`(runtime.thread)

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

proc bounce*[T: Continuation](c: sink T): T {.inline.} =
  var c: Continuation = move c
  if c.running:
    try:
      var y = c.fn
      var x = y(c)
      c = x
    except CatchableError:
      # NOTE: it will always be dismissed...
      when cpsStackFrames:
        if not c.dismissed:
          c.writeStackFrames()
      raise
  result = T c

proc dispatcherImpl[A, B](runtime: Runtime[A, B]) =
  block:
    const name: cstring = $A
    var c: A
    while true:
      case runtime.state
      of Uninitialized:
        raise Defect.newException:
          "dispatched runtime is uninitialized"
      of Launching:
        var prior: cint
        var phase =
          when insideoutDetached:
            0
          else:
            1
        while runtime.state == Launching:
          runtime[].result =
            case phase
            of 0:
              pthread_detach(runtime[].handle)
            of 1:
              pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)
            of 2:
              pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED.cint, addr prior)
            of 3:
              pthread_setname_np(runtime[].handle, name)
            else:
              runtime[].setState(Running)
              0
          if runtime[].result == 0:
            inc phase
          else:
            runtime[].setState(Stopping)
      of Running:
        if dismissed c:
          c = runtime[].factory.call(runtime.mailbox)
        try:
          var x = bounce(move c)
          if dismissed x:
            runtime[].setState(Stopping)
          elif finished x:
            reset x.mom
            reset x
            runtime[].setState(Stopping)
          else:
            sleepyMonkey()
            c = move x
        except CatchableError as e:
          when compileOption"stackTrace":
            writeStackTrace()
            # NOTE: it will always be dismissed...
            when cpsStackFrames:
              if not dismissed c:
                c.writeStackFrames()
          stdmsg().writeLine:
            renderError e
          runtime[].result =
            if errno == 0:
              1
            else:
              errno
          runtime[].setState(Stopping)
      of Stopping:
        when defined(gcOrc):
          GC_runOrc()
        when insideoutDetached:
          runtime[].setState(Stopped)
        break
      of Stopped:
        break

  when insideoutDetached:
    pthread_exit(addr runtime[].result)

when insideoutNimThreads:
  proc dispatcher[A, B](runtime: Runtime[A, B]) {.thread.} =
    ## thread-local continuation dispatch
    {.cast(gcsafe).}:
      dispatcherImpl(runtime)
else:
  proc dispatcher[A, B](p: pointer): pointer {.noconv.} =
    ## thread-local continuation dispatch
    dispatcherImpl(cast[Runtime[A, B]](p))

proc spawn[A, B](runtime: var RuntimeObj[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
  ## add compute to mailbox
  runtime.factory = factory
  runtime.mailbox = mailbox
  assertReady runtime
  runtime.setState(Launching)
  when insideoutNimThreads:
    createThread(runtime.thread, dispatcher, runtime.runtime)
  else:
    var attr: PThreadAttr
    doAssert 0 == pthread_attr_init(addr attr)
    when insideoutDetached:
      doAssert 0 == pthread_attr_setdetachstate(addr attr,
                                                PTHREAD_CREATE_DETACHED.cint)
    doAssert 0 == pthread_attr_setstacksize(addr attr, insideoutStackSize.cint)
    doAssert 0 == pthread_create(addr runtime.handle, addr attr,
                                 dispatcher[A, B], cast[pointer](addr runtime))
    doAssert 0 == pthread_attr_destroy(addr attr)

proc spawn*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]): Runtime[A, B] =
  ## create compute from a factory and mailbox
  new result
  initLock result[].changer
  initCond result[].changed
  spawn(result[], factory, mailbox)

proc clone*[A, B](runtime: Runtime[A, B]): Runtime[A, B] =
  ## clone a `runtime` to perform the same work
  assertReady runtime[]
  new result
  spawn(result[], runtime[].factory, runtime[].mailbox)

template running*(runtime: Runtime): bool =
  ## true if the runtime yet runs
  runtime.state in {Launching, Running}

proc factory*[A, B](runtime: Runtime[A, B]): Factory[A, B] {.inline.} =
  ## recover the factory from the runtime
  runtime[].factory

proc mailbox*[A, B](runtime: Runtime[A, B]): Mailbox[B] {.inline.} =
  ## recover the mailbox from the runtime
  runtime[].mailbox

proc pinToCpu*(runtime: Runtime; cpu: Natural) {.inline.} =
  ## assign a runtime to a specific cpu index
  if runtime.ran:
    pinToCpu(runtime[].handle, cpu)
  else:
    raise ValueError.newException "runtime unready to pin"

proc self*(): PThread =
  pthread_self()

proc handle*(runtime: Runtime): PThread =
  if runtime.isNil:
    raise Defect.newException "runtime uninitialized"
