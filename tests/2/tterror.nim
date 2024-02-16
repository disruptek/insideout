import pkg/cps

import insideout
#import insideout/backlog

const N = 2

proc foo(i: int) {.cps: Continuation.} =
  ## do something... or rather, nothing
  #debug "did nothing ", i

proc main() =
  let remote = newMailbox[Continuation]()
  block:
    var pool = newPool(ContinuationRunner, remote, initialSize = N)
    doAssert pool.count == N
    for i in 1..N:
      #info "send ", i
      remote.send:
        whelp foo(i)
    #info "might join"
main()
