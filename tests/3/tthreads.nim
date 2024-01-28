import std/atomics
import std/os
import std/locks

import pkg/cps
import insideout

var N = 1000
if isUnderValgrind():
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
  var ran: Atomic[int]

  proc goodbye(box: Mailbox[Continuation]) {.cps: Continuation.} =
    var c = recv box
    while c.running:
      var f: proc (x: sink Continuation): Continuation {.nimcall.} = c.fn
      var n = f(c)
      c = n
      if load(ran) == N:
        discard

  proc hello() {.cps: Continuation.} =
    atomicInc ran

  proc main() =
    let remote = newMailbox[Continuation](N)
    var pool = newPool(whelp(goodbye), remote, initialSize = N)

    doAssert pool.count == N

    for n in 1..N:
      remote.send:
        whelp hello()

    waitForEmpty remote
    disablePush remote
    echo "ran ", ran.load, " continuations"
    doAssert ran.load == N

  main()
