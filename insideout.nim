import pkg/cps

import insideout/pools
import insideout/mailboxes
import insideout/runtimes

export pools
export mailboxes
export runtimes

template debug(arguments: varargs[untyped, `$`]): untyped =
  when not defined(release):
    echo arguments

proc goto*[T](continuation: var T; where: Mailbox[T]): T {.cpsMagic.} =
  ## move the current continuation to another compute domain
  debug "goto ", where
  # we want to be sure that a future destroy finds nothing,
  # so we move the continuation and then send /that/ ref.
  var message = move continuation
  where.send message
  result = nil.T

proc waitron(box: Mailbox[Continuation]) {.cps: Continuation.} =
  ## generic blocking mailbox consumer
  while true:
    debug box, " recv"
    var mail = recv box
    debug box, " got mail"
    if dismissed mail:
      debug box, " dismissed"
      break
    else:
      debug box, " run begin"
      discard trampoline(move mail)
      debug box, " run end"
  debug box, " end"

template createWaitron*(A: typedesc; B: typedesc): untyped =
  proc ron(box: Mailbox[B]) {.cps: A.} =
    ## generic blocking mailbox consumer
    while true:
      debug box, " recv"
      var mail = recv box
      debug box, " got mail"
      if dismissed mail:
        debug box, " dismissed"
        break
      else:
        debug box, " run begin"
        discard trampoline(move mail)
        debug box, " run end"
    debug box, " end"
  whelp ron

const
  ContinuationWaiter* = createWaitron(Continuation, Continuation)

type
  ComeFrom = ref object of Continuation
    reply: Mailbox[Continuation]

proc landing(c: sink Continuation): Continuation =
  (ComeFrom c).reply.send(move c.mom)

proc comeFrom*[T](c: var T; into: Mailbox[T]): Continuation {.cpsMagic.} =
  ## move the continuation to the given mailbox; control
  ## resumes in the current thread when successful

  # NOTE: the mom, which is Continuation, defines the reply mailbox type;
  #       thus, the return value of comeFrom()
  var reply = newMailbox[Continuation](1)
  c.mom = ComeFrom(fn: landing, mom: move c.mom, reply: reply)
  into.send(c)
  result = recv reply

proc novelThread*[T](c: var T): T {.cpsMagic.} =
  ## move to a new thread; control resumes
  ## in the current thread when complete
  ## NOTE: specifying [T] goes away if cps loses color
  const Waiter = createWaitron(T, T)
  var mailbox = newMailbox[T](1)
  var runtime = spawn(Waiter, mailbox)
  result = cast[T](comeFrom(c, mailbox))
  quit runtime
