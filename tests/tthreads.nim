import pkg/cps
import pkg/insideout
import pkg/insideout/monkeys

var N = 10_000
if isUnderValgrind():
  N = N div 10
if insideoutSleepyMonkey > 0:
  N = N div 10

proc main() =
  let remote = newMailbox[Continuation]()
  var pool {.used.} = newPool(ContinuationWaiter, remote, initialSize = N)

main()
