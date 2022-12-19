import std/hashes
import std/strutils

import pkg/cps

import insideout/atomic/refs
import insideout/mailboxes
export refs

type
  Factory[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

  Work[A, B] = object
    factory: Factory[A, B]
    mailbox: ptr Mailbox[B]

  RuntimeObj[A, B] = object
    mailbox: Mailbox[B]
    thread: Thread[Work[A, B]]

  Runtime*[A, B] = AtomicRef[RuntimeObj[A, B]]

  ContinuationFactory[T] = Factory[Continuation, T]
  ContinuationWork[T] = Work[Continuation, T]
  ContinuationRuntime*[T] = Runtime[Continuation, T]

proc `=copy`*[A, B](runtime: var RuntimeObj[A, B]; other: RuntimeObj[A, B]) {.error.} =
  ## copies are denied
  discard

proc ran*[A, B](runtime: var Runtime[A, B]): bool =
  ## true if the runtime has run
  not runtime.isNil and not runtime[].mailbox.isNil

proc hash*(runtime: var Runtime): Hash =
  ## whatfer inclusion in a table, etc.
  mixin address
  hash cast[int](address runtime)

proc `$`*(runtime: var Runtime): string =
  result = "<run:"
  result.add hash(runtime).int.toHex(6)
  if runtime.ran:
    result.add: ".ran"
  result.add ">"

proc `==`*(a, b: Runtime): bool =
  mixin hash
  hash(a) == hash(b)

proc join*(runtime: var RuntimeObj) {.inline.} =
  ## wait for a running runtime to stop running;
  ## returns immediately if the runtime never ran
  if not runtime.mailbox.isNil:
    joinThread runtime.thread
    reset runtime.mailbox

proc join*(runtime: var Runtime) {.inline.} =
  join runtime[]

proc `=destroy`*[A, B](runtime: var RuntimeObj[A, B]) =
  ## ensure the runtime has stopped before it is destroyed
  mixin `=destroy`
  mixin join
  join runtime
  reset runtime.thread.data.mailbox
  `=destroy`(runtime.thread)

template assertReady(work: Work): untyped =
  if work.mailbox.isNil:
    raise ValueError.newException "nil mailbox"
  elif work.factory.fn.isNil:
    raise ValueError.newException "nil factory function"
  elif work.mailbox[].isNil:
    raise ValueError.newException "mailbox uninitialized"

proc dispatcher(work: Work) {.thread.} =
  ## thread-local continuation dispatch
  assertReady work
  {.cast(gcsafe).}:
    discard trampoline work.factory.call(work.mailbox[])

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
    assertReady runtime[].thread.data
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

proc spawn*[A, B](factory: Factory[A, B]): var Runtime[A, B] =
  ## create compute from a factory
  discard spawn(result, factory)

proc spawn*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]): var Runtime[A, B] =
  ## create compute from a factory and mailbox
  spawn(result, factory, mailbox)

proc quit*[A, B](runtime: var Runtime[A, B]) =
  ## ask the runtime to exit
  # FIXME: use a signal
  if runtime.ran:
    runtime[].mailbox.send nil.B

proc running*(runtime: var Runtime): bool {.inline.} =
  ## true if the runtime yet runs
  runtime[].thread.running

proc mailbox*[A, B](runtime: var Runtime[A, B]): Mailbox[B] {.inline.} =
  ## recover the mailbox from the runtime
  runtime[].mailbox

proc pinToCpu*(runtime: var Runtime; cpu: Natural) {.inline.} =
  ## assign a runtime to a specific cpu index
  if runtime.ran:
    pinToCpu(runtime.thread, cpu)
  else:
    raise ValueError.newException "runtime unready to pin"
