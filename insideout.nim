import std/private/threadtypes

import pkg/cps

import insideout/pools
import insideout/mailboxes
import insideout/runtimes

export pools
export mailboxes
export runtimes

proc pthread_signal(thread: SysThread; signal: cint)
  {.importc: "pthread_kill", header: pthreadh.}

template debug(arguments: varargs[untyped, `$`]): untyped =
  when not defined(release):
    echo arguments

proc goto*[T](c: sink T; where: Mailbox[T]): T {.cpsMagic.} =
  ## move the current continuation to another compute domain
  debug "goto ", where
  where.send c
  result = nil.T

template tempoline*(supplied: typed): untyped =
  ## cps-able trampoline
  block:
    var c: Continuation = move supplied
    while c.running:
      try:
        c = c.fn(c)
      except Exception:
        writeStackFrames()
        raise
    if not c.dismissed:
      disarm c
      c = nil

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
      discard trampoline mail
      debug box, " run end"
  debug box, " end"

const
  ContinuationWaiter* = whelp waitron
