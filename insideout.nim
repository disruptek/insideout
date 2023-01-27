when (NimMajor, NimMinor) < (1, 7):
  {.error: "insideout requires nim >= 1.7".}

import std/genasts
import std/macros

import pkg/cps

import insideout/pools
import insideout/mailboxes
import insideout/runtimes

export pools
export mailboxes
export runtimes

proc goto*[T](continuation: var T; where: Mailbox[T]): T {.cpsMagic.} =
  ## move the current continuation to another compute domain
  # we want to be sure that a future destroy finds nothing,
  # so we move the continuation and then send /that/ ref.
  var message = move continuation
  where.send message
  result = nil.T

macro createWaitron*(A: typedesc; B: typedesc): untyped =
  ## The compiler really hates when you do this one thing;
  ## but they cannot stop you!
  let name =
    nskProc.genSym:
      "waitron " & repr(A) & " To " & repr(B)
  name.copyLineInfo(A)
  genAstOpt({}, name, A, B):
    proc name(box: Mailbox[B]) {.cps: A.} =
      ## generic blocking mailbox consumer
      while true:
        var mail = recv box
        if dismissed mail:
          break
        else:
          discard trampoline(move mail)
    whelp name

const
  ContinuationWaiter* = createWaitron(Continuation, Continuation)

type
  ComeFrom = ref object of Continuation
    reply: Mailbox[Continuation]

proc landing(c: sink Continuation): Continuation =
  goto(c.mom, (ComeFrom c).reply)

proc comeFrom*[T](c: var T; into: Mailbox[T]): Continuation {.cpsMagic.} =
  ## move the continuation to the given mailbox; control
  ## resumes in the current thread when successful

  # NOTE: the mom, which is Continuation, defines the reply mailbox type;
  #       thus, the return value of comeFrom()
  var reply = newMailbox[Continuation](1)
  c.mom = ComeFrom(fn: landing, mom: move c.mom, reply: reply)
  discard goto(c, into)
  result = recv reply

proc novelThread*[T](c: var T): T {.cpsMagic.} =
  ## move to a new thread; control resumes
  ## in the current thread when complete
  ## NOTE: specifying `T` goes away if cps loses color
  const Waiter = createWaitron(T, T)
  var mailbox = newMailbox[T](1)
  var runtime = spawn(Waiter, mailbox)
  result = cast[T](comeFrom(c, mailbox))
  quit runtime
