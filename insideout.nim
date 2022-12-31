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

const
  ContinuationWaiter* = whelp waitron

type
  ComeFrom = ref object of Continuation
    returnTo: Mailbox[Continuation]

proc landing(c: sink Continuation): Continuation =
  (ComeFrom c).returnTo.send(move c.mom)

proc waiting(reply: Mailbox[Continuation]) {.cps: Continuation.} =
  discard trampoline(recv reply)

proc comeFrom*[T](c: var T; into: Mailbox[T]): Continuation {.cpsMagic.} =
  ## move the continuation to the given mailbox; control
  ## resumes in the current thread when successful
  var reply = newMailbox[Continuation](1)
  c.mom = ComeFrom(fn: landing, mom: move c.mom, returnTo: reply)
  into.send(T move c)
  result = whelp waiting(reply)
