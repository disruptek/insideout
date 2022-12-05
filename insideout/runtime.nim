import pkg/cps

import insideout/mailboxes

type
  Factory[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

  Work*[A, B] = object
    factory*: Factory[A, B]
    mailbox*: Mailbox[B]

  Runtime*[A, B] = object
    thread: Thread[Work[A, B]]

proc `=copy`*[A, B](runtime: var Runtime[A, B]; other: Runtime[A, B]) {.error.} =
  discard

proc wait*(runtime: var Runtime) {.inline.} =
  if runtime.thread.running:
    joinThread runtime.thread

proc `=destroy`*[A, B](runtime: var Runtime[A, B]) =
  ## ensure the runtime has stopped before it is destroyed
  wait runtime
  `=destroy`(runtime.thread)

proc dispatcher*[A, B](work: Work[A, B]) {.thread.} =
  ## thread-local continuation dispatch
  {.cast(gcsafe).}:
    discard trampoline work.factory.call(work.mailbox)

proc hatch*[A, B](runtime: var Runtime[A, B]; mailbox: Mailbox[B]) =
  ## add compute to mailbox
  runtime.thread.data.mailbox = mailbox
  createThread(runtime.thread, dispatcher, runtime.thread.data)

proc hatch*[A, B](runtime: var Runtime[A, B]): Mailbox[B] =
  ## add compute and return new mailbox
  result = newMailbox[B](16)
  hatch(runtime, result)

proc hatch*[A, B](runtime: var Runtime[A, B]; factory: Factory[A, B]): Mailbox[B] =
  ## create compute from a factory
  runtime.thread.data.factory = factory
  result = hatch(runtime)

proc hatch*[A, B](factory: Factory[A, B]): Runtime[A, B] =
  ## create compute from a factory
  result.thread.data.factory = factory
  discard hatch(result)

proc quit*[A, B](runtime: var Runtime[A, B]) =
  ## ask the runtime to exit
  runtime.thread.data.mailbox.send nil.B

proc running*(runtime: var Runtime): bool {.inline.} =
  ## true if the runtime yet runs
  runtime.thread.running

proc mailbox*[A, B](runtime: var Runtime[A, B]): Mailbox[B] =
  ## recover the mailbox from a runtime
  runtime.thread.data.mailbox
