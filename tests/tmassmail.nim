import std/osproc

import pkg/cps
import pkg/insideout
import pkg/insideout/monkeys

var N = 10_000
if isUnderValgrind():
  N = N div 10
if insideoutSleepyMonkey > 0:
  N = N div 10

proc respond(mailbox: Mailbox[int]; x: int) {.cps: Continuation.} =
  mailbox.send(x)

proc application() {.cps: Continuation.} =
  var request = newMailbox[Continuation](N)
  var replies = newMailbox[int](N)
  var pool {.used.} =
    newPool[Continuation, Continuation](ContinuationWaiter, request,
                                        initialSize = countProcessors())
  var i = N
  while i > 0:
    request.send:
      whelp respond(replies, i)
    dec i

  while i < N:
    discard replies.recv()
    inc i

  doAssert not replies.tryRecv(i)
  echo "shutdown pool"
  shutdown pool
  echo "done"

proc main =
  application()

when isMainModule:
  main()
