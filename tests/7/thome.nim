import std/os

import pkg/cps

import insideout
import insideout/backlog

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

proc cooperate(c: Continuation): Continuation {.cpsMagic.} =
  c

proc oracle(box: Mailbox[Query]) {.cps: Oracle.} =
  ## the "server"; it does typical continuation stuff
  while true:
    var query: Query
    var receipt: WardFlag = tryRecv(box, query)
    case receipt
    of Unreadable:
      break
    of Received:
      rz query
      discard trampoline(move query)
    else:
      info receipt
      if not waitForPoppable(box):
        info "unavailable"
        break
    cooperate()
  info "oracle terminating"

# define a service using a continuation bootstrap
const SmartService = whelp oracle

proc application(home: Mailbox[Continuation]) {.cps: Continuation.} =
  # create a child service
  info "i am"
  var mail = newMailbox[Query]()
  block:
    var pool {.used.} = newPool(SmartService, mail, 1)

    # submit some questions, etc.
    var i = 10
    while i > 0:
      info "i am"
      discard ask(mail, i)
      info "i am"
      goto home
      info "i am"
      dec i
    info "i am"

    # go home and drain the pool
    goto home
    info "i am"
    stop pool
  info "no more pool"
  disablePush home
  info "i am"

proc main =
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
    info "application complete"
  info "program exit"

when isMainModule:
  main()
