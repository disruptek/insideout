import std/hashes
import std/strutils

import pkg/cps

import insideout/mailboxes

type
  Factory[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

  Work[A, B] = object
    factory: Factory[A, B]
    mailbox: ptr Mailbox[B]

  Runtime*[A, B] = object
    mailbox: Mailbox[B]
    thread: Thread[Work[A, B]]

  ContinuationFactory[T] = Factory[Continuation, T]
  ContinuationWork[T] = Work[Continuation, T]
  ContinuationRuntime*[T] = Runtime[Continuation, T]

proc `=copy`*[A, B](runtime: var Runtime[A, B]; other: Runtime[A, B]) {.error.} =
  ## copies are denied
  discard

proc ran*(runtime: var Runtime): bool =
  ## true if the runtime has run
  runtime.mailbox.isInitialized

proc hash*(runtime: var Runtime): Hash =
  ## whatfer inclusion in a table, etc.
  hash(cast[int](addr runtime))

proc `$`*(runtime: var Runtime): string =
  result = "<run:"
  result.add hash(runtime).int.toHex(6)
  if runtime.ran:
    result.add: ".ran"
  result.add ">"

proc join*(runtime: var Runtime) {.inline.} =
  ## wait for a running runtime to stop running;
  ## returns immediately if the runtime never ran
  if runtime.ran:
    joinThread runtime.thread
    reset runtime.mailbox

proc `=destroy`*[A, B](runtime: var Runtime[A, B]) =
  ## ensure the runtime has stopped before it is destroyed
  join runtime
  reset runtime.thread.data.mailbox
  `=destroy`(runtime.thread)

template assertReady(work: Work): untyped =
  if work.mailbox.isNil:
    raise ValueError.newException "nil mailbox"
  elif work.factory.fn.isNil:
    raise ValueError.newException "nil factory function"
  elif not work.mailbox[].isInitialized:
    raise ValueError.newException "mailbox uninitialized"

proc dispatcher(work: Work) {.thread.} =
  ## thread-local continuation dispatch
  assertReady work
  {.cast(gcsafe).}:
    discard trampoline work.factory.call(work.mailbox[])

proc spawn*[A, B](runtime: var Runtime[A, B]; mailbox: Mailbox[B]) =
  ## add compute to mailbox
  runtime.mailbox = mailbox
  # XXX we assume that the runtime outlives the thread
  runtime.thread.data.mailbox = addr runtime.mailbox
  assertReady runtime.thread.data
  createThread(runtime.thread, dispatcher, runtime.thread.data)

proc spawn*[A, B](runtime: var Runtime[A, B]): Mailbox[B] =
  ## add compute and return new mailbox
  result = newMailbox[B]()
  spawn(runtime, result)

proc spawn*[A, B](runtime: var Runtime[A, B]; factory: Factory[A, B]): Mailbox[B] =
  ## create compute from a factory and return new mailbox
  runtime.thread.data.factory = factory
  result = spawn(runtime)

proc spawn*[A, B](runtime: var Runtime[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
  ## create compute from a factory and existing mailbox
  runtime.thread.data.factory = factory
  spawn(runtime, mailbox)

proc spawn*[A, B](factory: Factory[A, B]): Runtime[A, B] =
  ## create compute from a factory
  result.thread.data.factory = factory
  discard spawn(result)

proc spawn*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]): Runtime[A, B] =
  ## create compute from a factory and mailbox
  spawn(result, factory, mailbox)

proc quit*[A, B](runtime: var Runtime[A, B]) =
  ## ask the runtime to exit
  # FIXME: use a signal
  if runtime.ran:
    runtime.mailbox.send nil.B

proc running*(runtime: var Runtime): bool {.inline.} =
  ## true if the runtime yet runs
  runtime.thread.running

proc mailbox*[A, B](runtime: var Runtime[A, B]): Mailbox[B] {.inline.} =
  ## recover the mailbox from the runtime
  runtime.mailbox
