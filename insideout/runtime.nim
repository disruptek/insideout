import system/ansi_c

import pkg/cps

import insideout/mailboxes

type
  Factory[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

  Work[A, B] = object
    factory: Factory[A, B]
    mailbox: ptr Mailbox[B]

  Runtime*[A, B] = object
    mailbox*: Mailbox[B]
    thread: Thread[Work[A, B]]

proc `=copy`*[A, B](runtime: var Runtime[A, B]; other: Runtime[A, B]) {.error.} =
  discard

template ran*[A, B](runtime: Runtime[A, B]): bool =
  runtime.mailbox.isInitialized

proc wait*(runtime: var Runtime) {.inline.} =
  if runtime.ran:
    joinThread runtime.thread

proc `=destroy`*[A, B](runtime: var Runtime[A, B]) =
  ## ensure the runtime has stopped before it is destroyed
  wait runtime
  `=destroy`(runtime.thread)
  reset runtime.thread.data.mailbox
  reset runtime.mailbox

proc dispatcher*[A, B](work: Work[A, B]) {.thread.} =
  ## thread-local continuation dispatch
  if not work.mailbox.isNil:
    if not work.factory.fn.isNil:
      if work.mailbox[].isInitialized:
        {.cast(gcsafe).}:
          discard trampoline work.factory.call(work.mailbox[])

proc hatch*[A, B](runtime: var Runtime[A, B]; mailbox: Mailbox[B]) =
  ## add compute to mailbox
  runtime.mailbox = mailbox
  # XXX we assume that the runtime outlives the thread
  runtime.thread.data.mailbox = addr runtime.mailbox
  createThread(runtime.thread, dispatcher, runtime.thread.data)

proc hatch*[A, B](runtime: var Runtime[A, B]): Mailbox[B] =
  ## add compute and return new mailbox
  result = newMailbox[B](16)
  hatch(runtime, result)

proc hatch*[A, B](runtime: var Runtime[A, B]; factory: Factory[A, B]): Mailbox[B] =
  ## create compute from a factory
  runtime.thread.data.factory = factory
  result = hatch(runtime)

proc hatch*[A, B](runtime: var Runtime[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
  ## create compute from a factory and mailbox
  runtime.thread.data.factory = factory
  hatch(runtime, mailbox)

proc hatch*[A, B](factory: Factory[A, B]): Runtime[A, B] =
  ## create compute from a factory
  result.thread.data.factory = factory
  discard hatch(result)

proc quit*[A, B](runtime: var Runtime[A, B]) =
  ## ask the runtime to exit
  # FIXME: use a signal
  if runtime.mailbox.isInitialized:
    runtime.mailbox.send nil.B

proc running*(runtime: var Runtime): bool {.inline.} =
  ## true if the runtime yet runs
  runtime.thread.running
