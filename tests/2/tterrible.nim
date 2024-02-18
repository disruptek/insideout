import std/os

import pkg/cps

import insideout
#import insideout/backlog

const M = 2
let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    1_000
  else:
    100_000


proc foo(a, b: Mailbox[ref int]; i: int) {.cps: Continuation.} =
  echo "hello ", i
  while true:
    var i: ref int
    var r = a.tryRecv(i)
    case r
    of Received:
      #echo "foo ", i[], " a.len: ", a.len, " b.len: ", b.len
      while Delivered != b.trySend(i):
        echo "send fail ", i[]
        discard
    else:
      #echo "a: ", r, " a.len: ", a.len
      if not a.waitForPoppable():
        echo "failed out of foos"
        break
  echo "goodbye ", i

proc main(n: int) =
  # where to do work
  var remote = newMailbox[Continuation]()
  # move messages from a into b
  var a = newMailbox[ref int](n.uint32)    # input queue limited to thread count
  var b = newMailbox[ref int](N.uint32)    # output queue limited to message count
  # start the workers
  var pool = newPool(ContinuationWaiter, remote, initialSize = n)  # thread count
  # send the workers the work
  for i in 1..n:
    var c = whelp foo(a, b, i)
    while Delivered != remote.trySend(c):
      discard
  echo "done continuations"
  closeWrite remote
  # send the messages
  for i in 0..N:
    var x: ref int
    new x
    x[] = i
    #echo "send ", i, " a.len: ", a.len
    while Delivered != a.trySend(x):
      discard
  # there will be no more messages
  echo "done sends"
  closeWrite a
  var z = N
  while z > 0:
    var x: ref int
    var r = b.tryRecv(x)
    case r
    of Received:
      #echo "recv ", x[], " ", z, " remain"
      discard
    elif not b.waitForPoppable():
      echo "failed out of receives"
      break
    dec z
  echo "done ", N-z, " receives"
  # confirm that we received all the messages
  if z != 0:
    echo "missing ", z, " messages"
    quit 1
  # confirm that we didn't receive extra messages
  var x: ref int
  var r = b.tryRecv(x)
  if r != Empty:
    echo "receipt ", r
    quit 1
  echo "close receive"
  closeRead b
  echo "halt pool"
  halt pool
  echo "cancel pool"
  cancel pool
  echo "join pool"
  join pool

for n in 1..M:
  main(n)