import std/os

import pkg/cps

import insideout
#import insideout/backlog

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

from pkg/balls import checkpoint

proc oracle(box: Mailbox[Query]) {.cps: Oracle.} =
  ## the "server"; it does typical continuation stuff
  setupOracle()
  while true:
    var query: Query
    reset query
    checkpoint "oracle waiting for", box.reveal
    case box.tryRecv(query)
    of Received:
      rz query
      checkpoint "run", getThreadId()
      discard trampoline(move query)
    elif not waitForPoppable(box):
      #info "unavailable"
      break
    reset query
    cooperate()
    reset query
  #info "oracle terminating"
  checkpoint "oracle terminating", box.reveal

# define a service using a continuation bootstrap
const SmartService = whelp oracle

proc application(home: Mailbox[Continuation]) {.cps: Continuation.} =
  # create a child service
  #info "application starting"
  block:
    #notice "init mailbox"
    checkpoint "init query mailbox", getThreadId()
    var mail = newMailbox[Query]()
    checkpoint "init query mailbox done", mail.reveal
    #notice "mailbox init"
    block:
      var pool {.used.} = newPool(SmartService, mail, 1)

      # submit some questions, etc.
      var i = 4
      while i > 0:
        #info "asking... #", i
        discard ask(mail, i)
        #info "asked."
        goto home
        #info "home again"
        dec i
      #info "queries complete"
      # joining provokes a futex error
      #join pool
      # not joining causes an unreadable mailbox error
    checkpoint "gone pool", getThreadId()
    #info "no more pool"
    closeWrite home
  #notice "no more mail"
  #info "application exit"
  checkpoint "gone query mailbox", getThreadId()

proc main =
  block:
    #notice "init home mailbox"
    checkpoint "init home mailbox", getThreadId()
    var home = newMailbox[Continuation]()
    checkpoint "init home mailbox done"
    #notice "done init home mailbox"
    block:
      var c = Continuation: whelp application(home)
      while c.running:
        checkpoint "c is running", getThreadId()
        discard trampoline(move c)
        doAssert c.isNil
        try:
          checkpoint "recv", home.reveal
          c = recv home
          checkpoint "caught c", getThreadId()
        except ValueError as e:
          checkpoint $getThreadId(), "recv() raised" & e.msg
          break
    checkpoint "kill home mailbox", home.reveal
  checkpoint "gone home mailbox"
  #info "program exit"

main()
checkpoint "gone main()"
