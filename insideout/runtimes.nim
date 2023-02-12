import std/atomics
import std/hashes
import std/locks
import std/posix
import std/strutils

import pkg/cps

import insideout/atomic/refs
export refs

import insideout/mailboxes
import insideout/threads
import insideout/monkeys

type
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
    change: Cond
    result: cint

  Runtime*[A, B] = AtomicRef[RuntimeObj[A, B]]
  ContinuationRuntime*[T] = Runtime[Continuation, T]

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
          initCond runtime.change
        else:
          sleepyMonkey()
          broadcast runtime.change
        break

proc state*(runtime: Runtime): RuntimeState =
  if runtime.isNil:
    Uninitialized
  else:
    runtime[].state

proc ran*[A, B](runtime: var Runtime[A, B]): bool =
  ## true if the runtime has run
  runtime.state >= Launching

proc hash*(runtime: Runtime): Hash =
  ## whatfer inclusion in a table, etc.
  mixin address
  hash cast[int](address runtime)

proc `$`*(runtime: var Runtime): string =
  result = "<run:"
  result.add hash(runtime).int.toHex(6)
  result.add "-"
  result.add $runtime.state
  result.add ">"

proc `==`*(a, b: Runtime): bool =
  mixin hash
  hash(a) == hash(b)

proc join(runtime: var RuntimeObj): int {.inline.} =
  while true:
    case runtime.state
    of Uninitialized:
      raise ValueError.newException:
        "attempt to join uninitialized runtime"
    of Launching:
      discard  # spin
    of Stopped:
      break
    else:
      var value = cast[pointer](addr runtime.result)  # var for nim-1.6
      result = pthread_join(runtime.thread.handle(), addr value)
      runtime.setState(Stopped)

proc join*(runtime: var Runtime): int {.discardable, inline.} =
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
    deinitCond runtime.change
  reset runtime.mailbox
  `=destroy`(runtime.thread)

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

proc dispatcher[A, B](work: Work[A, B]) {.thread.} =
  ## thread-local continuation dispatch
  const name: cstring = $A
  while true:
    case work.runtime[].state
    of Uninitialized:
      raise Defect.newException:
        "dispatched runtime is uninitialized"
    of Launching:
      var attempt, prior: cint
      if attempt == 0:
        attempt = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)
      if attempt == 0:
        attempt = pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED.cint, addr prior)
      if attempt == 0:
        attempt = pthread_setname_np(work.runtime[].thread.handle(), name)
      work.runtime[].result = attempt
      work.runtime[].setState:
        if work.runtime[].result == 0:
          Running
        else:
          Stopping
    of Running:
      {.cast(gcsafe).}:
        try:
          var c = work.factory.call(work.mailbox[])
          trampolineIt c:
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
      break
    of Stopped:
      break

template factory(runtime: var Runtime): untyped =
  runtime[].thread.data.factory

proc spawn*[A, B](runtime: var Runtime[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
  ## add compute to mailbox
  if runtime.isNil:
    raise ValueError.newException "runtime is not initialized"
  elif not runtime[].mailbox.isNil and runtime[].mailbox != mailbox:
    raise ValueError.newException "spawn/3: attempt to change runtime mailbox"
  elif not runtime.factory.fn.isNil and runtime.factory != factory:
    raise ValueError.newException "spawn/3: attempt to change runtime factory"
  else:
    runtime[].thread.data.factory = factory
    runtime[].mailbox = mailbox
    # XXX we assume that the runtime outlives the thread
    runtime[].thread.data.mailbox = addr runtime[].mailbox
    # XXX we assume that the runtime address begins with the runtime object
    runtime[].thread.data.runtime = addr runtime[]
    assertReady runtime[].thread.data
    runtime[].setState(Launching)
    createThread(runtime[].thread, dispatcher, runtime[].thread.data)

proc spawn*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]): Runtime[A, B] =
  ## create compute from a factory and mailbox
  new result
  spawn(result, factory, mailbox)

proc quit*[A, B](runtime: var Runtime[A, B]) =
  ## ask the runtime to exit
  # FIXME: use a signal
  if runtime.ran:
    runtime[].mailbox.send nil.B

proc running*(runtime: var Runtime): bool {.inline.} =
  ## true if the runtime yet runs
  runtime.state in {Launching, Running}

proc mailbox*[A, B](runtime: var Runtime[A, B]): Mailbox[B] {.inline.} =
  ## recover the mailbox from the runtime
  runtime[].mailbox

proc pinToCpu*(runtime: var Runtime; cpu: Natural) {.inline.} =
  ## assign a runtime to a specific cpu index
  if runtime.ran:
    pinToCpu(runtime[].thread, cpu)
  else:
    raise ValueError.newException "runtime unready to pin"
