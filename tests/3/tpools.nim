import std/os
import pkg/cps
import pkg/insideout

quit 1

type
  Oracle = ref object of Continuation  ## server
    x: int

  Query = ref object of Continuation  ## client
    y: int

proc setupQueryWith(c: Query; y: int): Query {.cpsMagic.} =
  c.y = y
  result = c

proc value(c: Query): int {.cpsVoodoo.} = c.y

proc ask(mailbox: UnboundedFifo[Query]; x: int): int {.cps: Query.} =
  ## the "client"
  setupQueryWith x
  goto mailbox
  result = value()

proc rz(a: Oracle; b: Query): Oracle {.cpsMagic.} =
  ## fraternization
  if a.x >= int.high div 2:
    a.x = 1
  else:
    a.x *= 2
  b.y += a.x
  result = a

proc setupOracle(o: Oracle): Oracle {.cpsMagic.} =
  o.x = 1
  result = o

proc oracle(box: UnboundedFifo[Query]) {.cps: Oracle.} =
  ## the "server"; it does typical continuation stuff
  while true:
    sleep 1000
    var query: Query
    var receipt: WardFlag = tryRecv(box, query)
    debugEcho receipt
    case receipt
    of Paused, Empty:
      if not waitForPoppable(box):
        # the mailbox is unavailable
        echo "unavailable"
        break
      else:
        debugEcho "try again"
    of Readable:
      # the mailbox is unreadable
      echo "unreadable"
      break
    of Writable:
      rz query
      discard trampoline(move query)
      echo "wrote!"
    else:
      discard

# define a service using a continuation bootstrap
const SmartService = whelp oracle

proc application(home: UnboundedFifo[Continuation]) {.cps: Continuation.} =
  # create a child service
  echo "i am @ ", getThreadId()
  var mail = newMailbox[Query]()
  var pool {.used.} = newPool(SmartService, mail, 1)

  # submit some questions, etc.
  var i = 100
  while i > 0:
    echo "i am @ ", getThreadId()
    discard ask(mail, i)
    echo "i am @ ", getThreadId()
    goto home
    echo "i am @ ", getThreadId()
    dec i
  sleep 100
  echo "i am @ ", getThreadId()
  disablePush mail
  echo "disabled push"
  sleep 100

  # go home and drain the pool
  goto home
  echo "i am @ ", getThreadId()
  sleep 100
  for runtime in pool.mitems:
    cancel runtime
    echo runtime
  sleep 100

proc main =
  echo "\n\n\n"
  block:
    var home = newMailbox[Continuation]()
    var c = Continuation: whelp application(home)
    while not c.dismissed:
      discard trampoline(move c)
      doAssert c.isNil
      c = recv home
    echo "application complete"
  echo "program exit"

when isMainModule:
  main()
