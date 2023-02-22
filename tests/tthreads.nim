import std/atomics
import std/os
import std/locks

import pkg/cps
import pkg/insideout
import pkg/insideout/monkeys

var N = 1000
if isUnderValgrind():
  N = N div 10
if insideoutSleepyMonkey > 0:
  N = N div 10

block:
  ## pool with manual shutdown
  proc main() =
    let remote = newMailbox[Continuation](N)
    var pool = newPool(ContinuationWaiter, remote, initialSize = N)
    doAssert pool.count == N
    shutdown pool
    doAssert pool.count == 0

  main()

block:
  ## pool with automatic shutdown
  proc main() =
    let remote = newMailbox[Continuation](N)
    var pool = newPool(ContinuationWaiter, remote, initialSize = N)
    doAssert pool.count == N

  main()

block:
  ## runtimes exiting after running input continuations
  proc goodbye(box: Mailbox[Continuation]) {.cps: Continuation.} =
    var mail = recv box
    if not dismissed mail:
      discard trampoline(move mail)

  var ran: Atomic[int]

  proc hello() {.cps: Continuation.} =
    atomicInc ran

  proc main() =
    let remote = newMailbox[Continuation](N)
    var pool = newPool(whelp(goodbye), remote, initialSize = N)

    doAssert pool.count == N

    for n in 1..N:
      remote.send:
        whelp hello()

  main()
  doAssert ran.load == N
