import std/private/threadtypes

import pkg/cps

import insideout/pool
import insideout/mailboxes
import insideout/runtime

export pool
export mailboxes
export runtime

proc pthread_signal(thread: SysThread; signal: cint)
  {.importc: "pthread_kill", header: pthreadh.}

proc goto*[T](c: sink T; where: Mailbox[T]): T {.cpsMagic.} =
  where.send c

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
