import std/osproc

import pkg/cps
import pkg/insideout

const N = 1_000_000

proc respond(mailbox: Mailbox[int]; x: int) {.cps: Continuation.} =
  mailbox.send(x)

proc application() {.cps: Continuation.} =
  var request = newMailbox[Continuation](N)
  var replies = newMailbox[int](N)
  var pool = newPool[Continuation, Continuation](ContinuationWaiter, request,
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

proc main =
  application()

when isMainModule:
  main()
