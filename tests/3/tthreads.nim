import std/atomics

import pkg/cps
import insideout
import insideout/backlog

const T = 3
var N = 100
if isUnderValgrind():
  N = N div 10

proc foo(i: int) {.cps: Continuation.} =
  ## do something... or rather, nothing
  discard
  debug "nothing to do #", i

block:
  proc main() =
    notice "pool destroy joins"
    let remote = newMailbox[Continuation]()
    var pool = newPool(ContinuationRunner, remote, initialSize = T)
    doAssert pool.count == T
    for i in 1..T:
      debug "send ", i
      remote.send:
        whelp foo(i)
  main()

block:
  proc main() =
    notice "cancelled pool joins"
    let remote = newMailbox[Continuation]()
    var pool = newPool(ContinuationRunner, remote, initialSize = T)
    doAssert pool.count == T
    cancel pool
  main()

block:
  proc main() =
    notice "manual pool operations"
    let remote = newMailbox[Continuation](N)
    var pool = newPool(ContinuationWaiter, remote, initialSize = T)
    stop pool
    doAssert pool.count == T
    join pool
    doAssert pool.count == T
    empty pool
    doAssert pool.count == 0
  main()

block:
  proc main() =
    notice "structured concurrency"
    let remote = newMailbox[Continuation](N)
    block:
      var pool = newPool(ContinuationRunner, remote, initialSize = T)
      doAssert pool.count == T
      for i in 1..T:
        debug "send ", i
        while true:
          remote.send:
            whelp foo(i)
          break
      info "exiting block and joining"

  main()
