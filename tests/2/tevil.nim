## Two simple tests of runtimes:
##
## - Spinning: a continuation that does nothing but spin,
##             cooperating to return to the runtime's main
##             loop where it will be halted gracefully
##
## - Quitting: a continuation that does nothing but return

## We're testing that the runtimes can spawn, halt, and join with no
## timeouts, memory errors, races, etc. We manually halt and join the
## runtimes because we haven't learned about pools yet.

## This test was designed to expose bugs with runtime machinery which
## are not due to the mailboxes, so we use a void mailbox here and
## simply ignore it in the test.

import std/atomics
import std/os
import std/posix

import pkg/cps

import insideout/runtimes
import insideout/mailboxes
import insideout/valgrind

let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    1_000
  else:
    10_000

proc spinning() {.cps: Continuation.} =
  while true:
    coop()

proc quitting() {.cps: Continuation.} =
  discard

proc main() =

  block:
    ## dig them spinners
    #notice "[runtime] spawn"
    var runtime = spawn: whelp spinning()
    #info "[runtime] halt"
    halt runtime
    #info "[runtime] join"
    join runtime
    #info "[runtime] done"

  block:
    ## dig them quitters
    #notice "[runtime] spawn"
    var runtime = spawn: whelp quitting()
    #info "[runtime] halt"
    halt runtime
    #info "[runtime] join"
    join runtime
    #info "[runtime] done"

for i in 1..N:
  main()
