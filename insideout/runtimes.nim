import std/atomics
import std/hashes
import std/strutils

import pkg/cps

import insideout/atomic/refs
export refs

import insideout/mailboxes
import insideout/threads

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
    state: Atomic[RuntimeState]
    result: cint

  Runtime*[A, B] = AtomicRef[RuntimeObj[A, B]]
  ContinuationRuntime*[T] = Runtime[Continuation, T]

proc `=copy`*[A, B](runtime: var RuntimeObj[A, B]; other: RuntimeObj[A, B]) {.error.} =
  ## copies are denied
  discard

proc state(runtime: var RuntimeObj): RuntimeState =
  load(runtime.state, moAcquire)

proc state*(runtime: Runtime): RuntimeState =
  if runtime.isNil:
    Uninitialized
  else:
    state runtime[]

proc ran*[A, B](runtime: var Runtime[A, B]): bool =
  ## true if the runtime has run
  state(runtime) >= Launching

proc hash*(runtime: var Runtime): Hash =
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
  var status = state runtime
  if status >= Launching:
    # spin until the thread is running
    while status == Launching:
      status = state runtime
    if status < Stopped:
      let value = cast[pointer](addr runtime.result)
      result = pthreadJoin(runtime.thread.sys, addr value)
      store(runtime.state, Stopped)

proc join*(runtime: var Runtime): int {.discardable, inline.} =
  ## wait for a running runtime to stop running;
  ## returns immediately if the runtime never ran
  join runtime[]

proc `=destroy`*[A, B](runtime: var RuntimeObj[A, B]) =
  ## ensure the runtime has stopped before it is destroyed
  mixin `=destroy`
  discard join runtime
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
    elif load(work.runtime[].state, moAcquire) > Launching:
      raise ValueError.newException "already launched"

proc dispatcher(work: Work) {.thread.} =
  ## thread-local continuation dispatch
  assertReady work
  store(work.runtime[].state, Running)
  try:
    {.cast(gcsafe).}:
      discard trampoline work.factory.call(work.mailbox[])
  finally:
    store(work.runtime[].state, Stopping)

template factory(runtime: var Runtime): untyped =
  runtime[].thread.data.factory

proc spawn*[A, B](runtime: var Runtime[A, B]; mailbox: Mailbox[B]) =
  ## add compute to mailbox
  if runtime.isNil:
    raise ValueError.newException "runtime is not initialized"
  elif not runtime[].mailbox.isNil and runtime[].mailbox != mailbox:
    raise ValueError.newException "attempt to change runtime mailbox"
  else:
    runtime[].mailbox = mailbox
    # XXX we assume that the runtime outlives the thread
    runtime[].thread.data.mailbox = addr runtime[].mailbox
    # XXX we assume that the runtime address begins with the runtime object
    runtime[].thread.data.runtime = addr runtime[]
    assertReady runtime[].thread.data
    store(runtime[].state, Launching)
    createThread(runtime[].thread, dispatcher, runtime[].thread.data)

proc spawn*[A, B](runtime: var Runtime[A, B]): Mailbox[B] =
  ## add compute and return new mailbox
  result = newMailbox[B]()
  spawn(runtime, result)

proc spawn*[A, B](runtime: var Runtime[A, B]; factory: Factory[A, B]): Mailbox[B] =
  ## create compute from a factory and return new mailbox
  if runtime.isNil:
    new runtime
  elif not runtime.factory.fn.isNil and runtime.factory != factory:
    raise ValueError.newException "spawn/2: attempt to change runtime factory"
  runtime[].thread.data.factory = factory
  result = spawn(runtime)

proc spawn*[A, B](runtime: var Runtime[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
  ## create compute from a factory and existing mailbox
  if runtime.isNil:
    new runtime
  elif not runtime.factory.fn.isNil and runtime.factory != factory:
    raise ValueError.newException "spawn/3: attempt to change runtime factory"
  runtime[].thread.data.factory = factory
  spawn(runtime, mailbox)

proc spawn*[A, B](factory: Factory[A, B]): Runtime[A, B] =
  ## create compute from a factory
  new result
  discard spawn(result, factory)

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
