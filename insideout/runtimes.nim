import std/atomics
import std/hashes
import std/locks
import std/posix
import std/strutils

import pkg/cps

import insideout/atomic/refs
export refs

import insideout/mailboxes
import insideout/monkeys
import insideout/semaphores
import insideout/threads

const
  insideoutDetached* {.booldefine.} = false
  insideoutCancels* {.booldefine.} = false
  insideoutNimThreads* {.booldefine.} = false
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

  Work[A, B] = object
    factory: Factory[A, B]
    mailbox: ptr Mailbox[B]
    runtime: ptr RuntimeObj[A, B]

  RuntimeObj[A, B] = object
    mailbox: Mailbox[B]
    thread: Thread[Work[A, B]]
    status: Atomic[RuntimeState]
    changed: Cond
    changer: Lock
    result: cint
    pthread: PThread

  Runtime*[A, B] = AtomicRef[RuntimeObj[A, B]]

template handle(runtime: RuntimeObj): untyped =
  when insideoutNimThreads:
    cast[PThread](runtime.thread.handle)
  else:
    runtime.pthread

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
        if prior == Uninitialized:
          initCond runtime.changed
          initLock runtime.changer
        else:
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
      cast[Hash](runtime.handle)

proc `$`*(runtime: Runtime): string =
  result = "<run:"
  result.add hash(runtime).int.toHex(6)
  result.add "-"
  result.add $runtime.state
  result.add ">"

proc `==`*(a, b: Runtime): bool =
  mixin hash
  hash(a) == hash(b)

proc cancel[A, B](runtime: var RuntimeObj[A, B]): bool =
  when insideoutCancels:
    result = 0 == pthread_cancel(runtime.handle)
    if result:
      runtime.setState(Stopped)
  else:
    send(runtime.mailbox, nil.B)

proc kill[A, B](runtime: var RuntimeObj[A, B]; sig: int = 9): bool =
  when insideoutCancels:
    result = 0 == pthread_kill(runtime.handle, sig.cint)
    if result:
      runtime.setState(Stopped)
  else:
    send(runtime.mailbox, nil.B)

proc shutdown[A, B](runtime: var RuntimeObj[A, B]) =
  while true:
    case runtime.state
    of Uninitialized, Stopped:
      break
    of Running:
      runtime.setState(Stopping)
    of Stopping:
      if not cancel runtime:
        # XXX: lost thread?
        runtime.setState(Stopped)

proc join(runtime: var RuntimeObj): int {.inline.} =
  while true:
    case runtime.state
    of Uninitialized:
      raise ValueError.newException:
        "attempt to join uninitialized runtime"
    of Launching:
      discard wait runtime
    of Running:
      discard runtime.cancel() # XXX: temporary
      runtime.setState(Stopping)
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
  join runtime[]

proc `=destroy`*[A, B](runtime: var RuntimeObj[A, B]) =
  ## ensure the runtime has stopped before it is destroyed
  mixin `=destroy`
  if runtime.state != Uninitialized:
    discard join runtime
    withLock runtime.changer:
      broadcast runtime.changed
    deinitLock runtime.changer
    deinitCond runtime.changed
  reset runtime.mailbox
  `=destroy`(runtime.thread)
  store(runtime.status, Uninitialized)

template assertReady(work: Work): untyped =
  when not defined(danger):  # if this isn't dangerous, i don't know what is
    if work.mailbox.isNil:
      raise ValueError.newException "nil mailbox"
    elif work.factory.fn.isNil:
      raise ValueError.newException "nil factory function"
    elif work.mailbox[].isNil:
      raise ValueError.newException "mailbox uninitialized"
    elif work.runtime.isNil:
      raise ValueError.newException "unbound to thread"
    elif work.runtime[].state != Uninitialized:
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
      if not c.dismissed:
        writeStackFrames c
      raise
  result = T c

proc dispatcherImpl[A, B](work: Work[A, B]) =
  block:
    const name: cstring = $A
    var c: A
    while true:
      case work.runtime[].state
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
        while work.runtime[].state == Launching:
          work.runtime[].result =
            case phase
            of 0:
              pthread_detach(work.runtime[].handle)
            of 1:
              pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)
            of 2:
              pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED.cint, addr prior)
            of 3:
              pthread_setname_np(work.runtime[].handle, name)
            else:
              work.runtime[].setState(Running)
              0
          if work.runtime[].result == 0:
            inc phase
          else:
            work.runtime[].setState(Stopping)
      of Running:
        if dismissed c:
          c = work.factory.call(work.mailbox[])
        try:
          c = bounce c
          if dismissed c:
            work.runtime[].setState(Stopping)
          elif finished c:
            reset c.mom
            reset c
            work.runtime[].setState(Stopping)
          else:
            sleepyMonkey()
        except CatchableError as e:
          stdmsg().writeLine:
            renderError e
          work.runtime[].result =
            if errno == 0:
              1
            else:
              errno
          work.runtime[].setState(Stopping)
      of Stopping:
        when defined(gcOrc):
          GC_runOrc()
        when insideoutDetached:
          work.runtime[].setState(Stopped)
        break
      of Stopped:
        break

  when insideoutDetached:
    pthread_exit(addr work.runtime[].result)

when insideoutNimThreads:
  proc dispatcher[A, B](work: Work[A, B]) {.thread.} =
    ## thread-local continuation dispatch
    {.cast(gcsafe).}:
      dispatcherImpl(work)
else:
  proc dispatcher[A, B](p: pointer): pointer {.noconv.} =
    ## thread-local continuation dispatch
    dispatcherImpl(cast[ptr Work[A, B]](p)[])

template factory(runtime: Runtime): untyped =
  runtime[].thread.data.factory

proc spawn[A, B](runtime: var RuntimeObj[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
  ## add compute to mailbox
  runtime.thread.data.factory = factory
  runtime.mailbox = mailbox
  # XXX we assume that the runtime outlives the thread
  runtime.thread.data.mailbox = addr runtime.mailbox
  # XXX we assume that the runtime address begins with the runtime object
  runtime.thread.data.runtime = addr runtime
  assertReady runtime.thread.data
  runtime.setState(Launching)
  when insideoutNimThreads:
    createThread(runtime.thread, dispatcher, runtime.thread.data)
  else:
    var attr: PThreadAttr
    doAssert 0 == pthread_attr_init(addr attr)
    when insideoutDetached:
      doAssert 0 == pthread_attr_setdetachstate(addr attr,
                                                PTHREAD_CREATE_DETACHED.cint)
    doAssert 0 == pthread_attr_setstacksize(addr attr, insideoutStackSize.cint)
    doAssert 0 == pthread_create(addr runtime.handle, addr attr,
                                 dispatcher[A, B],
                                 pointer(addr runtime.thread.data))
    doAssert 0 == pthread_attr_destroy(addr attr)

proc spawn*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]): Runtime[A, B] =
  ## create compute from a factory and mailbox
  new result
  spawn(result[], factory, mailbox)

proc quit*[A, B](runtime: Runtime[A, B]) =
  ## ask the runtime to exit
  when insideoutDetached:
    case runtime.state
    of Uninitialized, Stopped, Stopping:
      discard
    else:
      runtime[].setState(Stopping)
  else:
    runtime[].mailbox.send nil.B

template running*(runtime: Runtime): bool =
  ## true if the runtime yet runs
  runtime.state in {Launching, Running}

proc mailbox*[A, B](runtime: Runtime[A, B]): Mailbox[B] {.inline.} =
  ## recover the mailbox from the runtime
  runtime[].mailbox

proc pinToCpu*(runtime: Runtime; cpu: Natural) {.inline.} =
  ## assign a runtime to a specific cpu index
  if runtime.ran:
    when insideoutNimThreads:
      pinToCpu(runtime[].thread, cpu)
    else:
      discard
  else:
    raise ValueError.newException "runtime unready to pin"
