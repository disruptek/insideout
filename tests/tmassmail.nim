import std/osproc

import pkg/cps
import pkg/insideout
import pkg/insideout/monkeys

var N = 10_000
if isUnderValgrind():
  N = N div 10
if insideoutSleepyMonkey > 0:
  N = N div 10

proc noop(c: Continuation): Continuation {.cpsMagic.} = c

proc respond(mailbox: Mailbox[ref int]; x: int) {.cps: Continuation.} =
  ## create a local ref, enter a new continuation leg, send input to output
  var y: ref int
  new y
  y[] = x
  noop()
  mailbox.send(y)

proc application() {.cps: Continuation.} =
  var request = newMailbox[Continuation](N)
  var replies = newMailbox[ref int](N)
  var pool {.used.} =
    newPool[Continuation, Continuation](ContinuationWaiter, request,
                                        initialSize = countProcessors())
  var i = N
  while i > 0:
    var c = whelp respond(replies, i)
    # run the first leg locally, for orc cycle registration reasons
    c = bounce(move c)
    request.send(c)
    dec i

  while i < N:
    discard replies.recv()
    inc i

  # we should have consumed all outputs
  var ignore: ref int
  new ignore
  doAssert not replies.tryRecv(ignore)

  echo "shutdown pool"
  shutdown pool
  echo "done"

proc main =
  application()

when isMainModule:
  main()
