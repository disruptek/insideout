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
