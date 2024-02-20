import pkg/cps

import insideout
#import insideout/backlog

const N = 2

proc foo(i: int) {.cps: Continuation.} =
  ## do something... or rather, nothing
  echo "did nothing ", i

proc main() =
  let remote = newMailbox[Continuation]()
  block:
    var pool = newPool(ContinuationRunner, remote, initialSize = N)
    for i in 1..N:
      echo "send ", i
      var c = whelp foo(i)
      while Delivered != remote.trySend(c):
        discard
    echo "might join"

main()
