## Two simple tests of runtimes:
##
## - Spinning: a continuation that does nothing but spin,
##             cooperating to return to the runtime's main
##             loop where it can be halted gracefully
##
## - Quitting: a continuation that does nothing but return
##

## We're testing that the runtimes can spawn, halt, and join with no
## timeouts, memory errors, races, etc. We manually halt and join the
## runtimes because we haven't learned about pools yet.

## This test was designed to expose bugs with runtime machinery which
## are not due to the mailboxes, so we use void mailboxen here and
## essentially ignore them in the test.

import std/atomics
import std/os

import pkg/cps

import insideout/runtimes
import insideout/mailboxes
import insideout/valgrind

let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    1_000
  else:
    10_000

proc cooperate(c: Continuation): Continuation {.cpsMagic.} = c

proc spinning(jobs: Mailbox[void]) {.cps: Continuation.} =
  while true:
    cooperate()

proc quitting(jobs: Mailbox[void]) {.cps: Continuation.} =
  discard

const Spinning = whelp spinning
const Quitting = whelp quitting

proc main() =

  block:
    ## dig them spinners
    #notice "runtime"
    let none = newMailbox[void]()
    #info "[runtime] spawn"
    var runtime = Spinning.spawn(none)
    #info "[runtime] halt"
    halt runtime
    #info "[runtime] join"
    join runtime
    #info "[runtime] done"

  block:
    ## dig them quitters
    #notice "runtime"
    let none = newMailbox[void]()
    #info "[runtime] spawn"
    var runtime = Quitting.spawn(none)
    #info "[runtime] halt"
    halt runtime
    #info "[runtime] join"
    join runtime
    #info "[runtime] done"

for i in 1..N:
  main()
