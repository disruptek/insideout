import std/os
import pkg/cps
import pkg/insideout

type
  Oracle = ref object of Continuation  ## server
    x: int

  Query = ref object of Continuation  ## client
    y: int

proc setupQueryWith(c: Query; y: int): Query {.cpsMagic.} =
  c.y = y
  result = c

proc value(c: Query): int {.cpsVoodoo.} = c.y

proc ask(mailbox: Mailbox[Query]; x: int): int {.cps: Query.} =
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

proc oracle(box: Mailbox[Query]) {.cps: Oracle.} =
  ## the "server"; it does typical continuation stuff
  while true:
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
    else:
      discard

# define a service using a continuation bootstrap
const SmartService = whelp oracle

proc application(home: Mailbox[Continuation]) {.cps: Continuation.} =
  # create a child service
  echo "i am @ ", getThreadId()
  var mail = newMailbox[Query]()
  block:
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
    echo "i am @ ", getThreadId()

    # go home and drain the pool
    goto home
    echo "i am @ ", getThreadId()
    stop pool
    echo "stopped pool"
    cancel pool
    echo "cancelled pool"
    join pool
    echo "joined pool"
  echo "no more pool"
  disablePush home
  echo "i am @ ", getThreadId()

proc main =
  echo "\n\n\n"
  block:
    var home = newMailbox[Continuation]()
    var c = Continuation: whelp application(home)
    while c.running:
      discard trampoline(move c)
      doAssert c.isNil
      try:
        c = recv home
      except ValueError:
        break
    echo "application complete"
  echo "program exit"

when isMainModule:
  main()