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

proc oracle(box: Mailbox[Query]) {.cps: Oracle.} =
  ## the "server"; it does typical continuation stuff
  info "oracle starting"
  setupOracle()
  while true:
    var query: Query
    case box.tryRecv(query)
    of Received:
      rz query
      discard trampoline(move query)
    elif not waitForPoppable(box):
      break
    cooperate()
  info "oracle terminating"

# define a service using a continuation bootstrap
const SmartService = whelp oracle

proc application(home: Mailbox[Continuation]) {.cps: Continuation.} =
  # create a child service
  info "application starting"
  block:
    notice "init mailbox"
    var mail = newMailbox[Query]()
    notice "mailbox init"
    block:
      var pool {.used.} = newPool(SmartService, mail, 1)

      # submit some questions, etc.
      var i = 4
      while i > 0:
        info "asking... #", i
        discard ask(mail, i)
        info "asked."
        goto home
        info "home again"
        dec i
      closeWrite mail
      closeRead mail
      closeWrite home
      halt pool
    info "no more pool"
  notice "no more mail"
  info "application exit"

import std/os
proc main =
  block done:
    notice "init home mailbox"
    var home = newMailbox[Continuation]()
    notice "done init home mailbox"
    block:
      var c = Continuation: whelp application(home)
      while c.running:
        discard trampoline(move c)
        doAssert c.isNil
        while true:
          var r = home.tryRecv(c)
          case r
          of Received:
            info "receipt in main"
            break
          else:
            info "wait in main: ", r
            sleep 100
            if not home.waitForPoppable:
              info "break done"
              break done
  info "program exit"

main()
notice "done main"
