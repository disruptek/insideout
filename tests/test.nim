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

proc goto(c: sink Query; where: Mailbox[Query]): Query {.cpsMagic.} =
  where.send c

proc ask(mailbox: Mailbox[Query]; x: int): int {.cps: Query.} =
  ## the "client"
  setupQueryWith x
  echo "asking " & $x & " in " & $getThreadId()
  goto mailbox
  echo "recovering in " & $getThreadId()
  result = value()

template tempoline*(supplied: typed): untyped =
  ## cps-able trampoline
  block:
    var c: Continuation = move supplied
    while c.running:
      try:
        c = c.fn(c)
      except Exception:
        writeStackFrames()
        raise
    if not c.dismissed:
      disarm c
      c = nil

proc rz(a: Oracle; b: Query) {.cps: Continuation.} =
  ## fraternization
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

var working: Lock
proc application() {.cps: Continuation.} =
  withLock working:
    # create a child service
    var sensei: Pool[Oracle, Query]

    # fill the pool, hatching runtimes
    var address: Mailbox[Query]
    while true:
      if sensei.len == 0:
        address = sensei.fill.hatch SmartService
      elif sensei.len == 2000:
        break
      else:
        sensei.fill.hatch(SmartService, address)

    # submit some questions, etc.
    var i = 1_000
    while i > 0:
      echo "result is ", ask(address, i)
      dec i

    # drain the pool
    drain sensei

    # exit normally
    echo "application terminating"

proc main =
  echo "\n\n\n"
  block:
    var c = trampoline: whelp application()
    withLock working:
      echo "application complete"
      c = nil
  echo "program exit"

when isMainModule:
  main()
