when not defined(isNimSkull):
  when (NimMajor, NimMinor) < (1, 7):
    {.error: "insideout requires nim >= 1.7".}

when not defined(gcArc) and not defined(gcOrc):
  {.error: "insideout requires arc or orc memory management".}

when not defined(useMalloc):
  {.error: "insideout requires define:useMalloc".}

when not (defined(c) or defined(cpp)):
  {.error: "insideout requires backend:c or backend:cpp".}

when not (defined(posix) and compileOption"threads"):
  {.error: "insideout requires POSIX threads".}

import std/genasts
import std/macros

import pkg/cps

import insideout/pools
import insideout/mailboxes
import insideout/runtimes
import insideout/valgrind

when true:
  import insideout/backlog
  export backlog
else:
  template debug(args: varargs[untyped]) = discard

export mailboxes
export runtimes
export valgrind
export pools

proc goto*[T](continuation: var T; where: Mailbox[T]): T {.cpsMagic.} =
  ## move the current continuation to another compute domain
  # we want to be sure that a future destroy finds nothing,
  # so we move the continuation and then send /that/ ref.
  where.send(move continuation)
  result = nil.T

proc cooperate*(a: sink Continuation): Continuation {.cpsMagic.} =
  ## yield to the dispatcher
  a

macro createWaitron*(A: typedesc; B: typedesc): untyped =
  ## The compiler really hates when you do this one thing;
  ## but they cannot stop you!
  let name =
    nskProc.genSym:
      "waitron " & repr(A) & " To " & repr(B)
  name.copyLineInfo(A)
  genAstOpt({}, name, A, B):
    proc name(box: Mailbox[B]) {.cps: A.} =
      ## continuously consume and run `B` continuations
      mixin cooperate
      debug "starting waitron"
      while true:
        var c: Continuation
        var r: WardFlag = tryRecv(box, c.B)
        case r
        of Unreadable:
          debug "shutting down due to unreadable mailbox"
          break
        of Interrupt:
          debug "caught interrupt"
        of Received:
          while c.running:
            debug "will bounce continuation"
            c = bounce c
            cooperate()
          # reap the local in the cps environment
          reset c
        else:
          debug r, "; waiting for poppable"
          if not box.waitForPoppable():
            debug "shutting down due to unavailable mailbox"
            break
        cooperate()
      debug "exiting waitron"

    whelp name

macro createRunner*(A: typedesc; B: typedesc): untyped =
  ## Create a dispatcher, itself an `A` continuation,
  ## which runs a single `B` continuation and terminates.
  let name =
    nskProc.genSym:
      "runner " & repr(A) & " To " & repr(B)
  name.copyLineInfo(A)
  genAstOpt({}, name, A, B):
    proc name(box: Mailbox[B]) {.cps: A.} =
      ## run a single `B` continuation
      mixin cooperate
      debug "starting ", B, " runner"
      while true:
        var c: Continuation
        var r = box.tryRecv(B c)
        case r
        of Received:
          while c.running:
            debug "will bounce continuation"
            c = bounce c
            cooperate()
          reset c
          break
        of Unreadable:
          debug "shutting down due to unreadable mailbox"
          break
        of Interrupt:
          debug "caught interrupt"
        else:
          debug r, "; waiting for poppable"
          if not box.waitForPoppable():
            debug "shutting down due to unavailable mailbox"
            break
          debug "wait complete"
        cooperate()
      debug "exiting ", B, " runner"

    whelp name

const
  ContinuationWaiter* = createWaitron(Continuation, Continuation)
  ContinuationRunner* = createRunner(Continuation, Continuation)

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
  var reply = newMailbox[Continuation]()
  c.mom = ComeFrom(fn: landing, mom: move c.mom, reply: reply)
  discard goto(c, into)
  result = recv reply

proc novelThread*[T](c: var T): T {.cpsMagic.} =
  ## move to a new thread; control resumes
  ## in the current thread when complete
  ## NOTE: specifying `T` goes away if cps loses color
  const Waiter = createRunner(T, T)
  var mailbox = newMailbox[T](1)
  var runtime = spawn(Waiter, mailbox)
  result = cast[T](comeFrom(c, mailbox))
  join runtime
