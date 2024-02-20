import std/atomics
import std/os

#import pkg/balls
import pkg/cps

import insideout/runtimes
import insideout/mailboxes
import insideout/valgrind
#import insideout/backlog

let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    10_000
  else:
    100_000

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
