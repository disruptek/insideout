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
  debugEcho "asking " & $x & " in " & $getThreadId()
  comeFrom mailbox
  result = value()
  debugEcho "recovered " & $result & " in " & $getThreadId()

proc rz(a: Oracle; b: Query): Oracle {.cpsMagic.} =
  ## fraternization
  a.x *= 2
  b.y += a.x
  result = a

proc setupOracle(o: Oracle): Oracle {.cpsMagic.} =
  o.x = 1
  result = o

proc oracle(box: Mailbox[Query]) {.cps: Oracle.} =
  ## the "server"; it does typical continuation stuff
  setupOracle()
  while true:
    var query: Query
    case tryRecv(box, query)
    of Received:
      rz query
      discard trampoline(move query)
    elif not waitForPoppable(box):
      break
    coop()

# define a service using a continuation bootstrap
const SmartService = whelp oracle

proc application(): int {.cps: Continuation.} =
  # create a child service
  var mail = newMailbox[Query]()
  var pool = newPool(SmartService, mail, 1)
  let home = getThreadId()

  # submit some questions, etc.
  var i = 10
  while i > 0:
    result = ask(mail, i)
    dec i
    doAssert home == getThreadId()

  # we're still at home
  doAssert home == getThreadId()
  closeWrite mail
  halt pool

proc main =
  let was = application()
  doAssert was == 1025, "result was " & $was & " and not 1025"
  echo "application complete"

when isMainModule:
  main()
