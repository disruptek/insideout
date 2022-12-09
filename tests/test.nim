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

proc me(c: Oracle): Oracle {.cpsVoodoo.} = c

proc value(c: Query): int {.cpsVoodoo.} = c.y

proc ask(mailbox: Mailbox[Query]; x: int): int {.cps: Query.} =
  ## the "client"
  setupQueryWith x
  #echo "asking " & $x & " in " & $getThreadId()
  goto mailbox
  #echo "recover " & $x & " in " & $getThreadId()
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

proc oracle(mailbox: Mailbox[Query]) {.cps: Oracle.} =
  ## the "server"; it does typical continuation stuff
  setupOracle()
  while true:
    var query = recv mailbox
    if dismissed query:
      break
    else:
      rz query
      discard trampoline(move query)
      doAssert query.isNil

# define a service using a continuation bootstrap
const SmartService = whelp oracle

proc application(home: Mailbox[Continuation]) {.cps: Continuation.} =
  # create a child service
  var mail = newMailbox[Query]()
  var pool = newPool[Oracle, Query](SmartService, mail)

  # submit some questions, etc.
  var i = 1000
  while i > 0:
    #echo "result of ", i, " is ", ask(address, i)
    discard ask(mail, i)
    goto home
    dec i

  # go home and drain the pool
  goto home
  drain pool
  home.send nil.Continuation

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
