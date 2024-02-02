import std/atomics
import std/os

import pkg/cps
import insideout

const T = 2
var N = 1000
if isUnderValgrind():
  N = N div 10

proc foo() {.cps: Continuation.} =
  ## do something... or rather, nothing
  discard

block:
  proc main() =
    echo "pool destroy joins"
    let remote = newMailbox[Continuation]()
    var pool = newPool(ContinuationRunner, remote, initialSize = T)
    doAssert pool.count == T
    for i in 1..T:
      remote.send:
        whelp foo()
  main()

block:
  proc main() =
    echo "cancelled pool joins"
    let remote = newMailbox[Continuation]()
    var pool = newPool(ContinuationRunner, remote, initialSize = T)
    doAssert pool.count == T
    cancel pool
    echo "cancelled them"
  main()

block:
  proc main() =
    echo "manual pool operations"
    let remote = newMailbox[Continuation](N)
    var pool = newPool(ContinuationWaiter, remote, initialSize = T)
    doAssert pool.count == T
    echo "cancel"
    cancel pool
    doAssert pool.count == T
    echo "join"
    join pool
    doAssert pool.count == T
    echo "empty"
    empty pool
    doAssert pool.count == 0
  main()

block:
  proc main() =
    echo "pool with structured concurrency"
    let remote = newMailbox[Continuation](N)
    block:
      var pool = newPool(ContinuationRunner, remote, initialSize = T)
      doAssert pool.count == T
      for i in 1..T:
        remote.send:
          whelp foo()

  main()
