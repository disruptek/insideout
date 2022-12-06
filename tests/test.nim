import std/locks

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
  #echo "recovering in " & $getThreadId()
  result = value()

proc rz(a: Oracle; b: Query) {.cps: Continuation.} =
  ## fraternization
  if a.x >= int.high div 2:
    a.x = 1
  else:
    a.x *= 2
  b.y += a.x

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
      rz(me(), query)
      tempoline query

# define a service using a continuation bootstrap
const SmartService = whelp oracle

proc application(home: Mailbox[Continuation]) {.cps: Continuation.} =
  # create a child service
  var sensei: Pool[Oracle, Query]
  var address = sensei.fill.hatch SmartService

  # fill the pool, hatching runtimes
  while sensei.count < 100:
    sensei.fill.hatch(SmartService, address)

  # submit some questions, etc.
  var i = 100_000
  while i > 0:
    #echo "result is ", ask(address, i)
    discard ask(address, i)
    dec i

  # go home and drain the pool
  goto home
  drain sensei

proc main =
  echo "\n\n\n"
  block:
    var home = newMailbox[Continuation](1)
    var c = Continuation: whelp application(home)
    c = trampoline(c)
    c = recv home
    c = trampoline(c)
    echo "application complete"
  echo "program exit"

when isMainModule:
  main()
