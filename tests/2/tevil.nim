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
    100_000
  else:
    1_000_000

proc cooperate(c: Continuation): Continuation {.cpsMagic.} = c

proc spinning(jobs: Mailbox[void]) {.cps: Continuation.} =
  while true:
    cooperate()

const Spinning = whelp spinning

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

for i in 1..N:
  main()
