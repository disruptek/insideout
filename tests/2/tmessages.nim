## create a number of queues, each with a single producer and consumer.
## measure the time taken to move `N` messages through the queues.
##
import std/atomics
import std/os
import std/osproc
import std/strutils
import std/strformat
import std/times

import pkg/cps

import insideout
import insideout/backlog

let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    1_000
  else:
    100_000

const zz = 1000

proc drainer(queue: Mailbox[ref int]; j: int; n: int) {.cps: Continuation.} =
  ## remove `n` messages from `queue` and assert that they are in the range 1..`n`
  var m = n
  #info "drainer", j, " begin receiving ", m, " messages"
  var z = 0
  while m > 0:
    var i: ref int
    var r = queue.tryRecv(i)
    case r
    of Received:
      assert i[] <= n
      dec m
      z = 0
    of Interrupt: discard
    else:
      if r == Empty:
        inc z
        if z == 10000:
          fatal "drainer", j, " ", r, " wants ", m, " but q.len: ", queue.len
          sleep zz
          quit 1
        if not queue.waitForPoppable:
          if m > 0:
            fatal "drainer", j, " ", r, " wants ", m, " but unread: ", queue.len
            sleep zz
            quit 1
          break
  info "drainer", j, " complete"

proc filler(queue: Mailbox[ref int]; j: int; m: int) {.cps: Continuation.} =
  ## add `m` messages to `queue`
  info "filler", j, " begin sending ", m, " messages"
  var m = m
  while m > 0:
    var i: ref int
    new i
    i[] = m
    var r = queue.trySend(i)
    case r
    of Delivered:
      dec m
    of Interrupt: discard
    of Full: discard
    elif not queue.waitForPushable:
      info "filler", j, " ", r, " has ", m, " but not pushable"
      break
  queue.closeWrite()
  #info "filler", j, " complete"

proc attempt(N: Positive; cores: int = countProcessors()) =
  let now = getTime()
  var queues: seq[Mailbox[ref int]]
  block:
    info "filling queues with ", N, " work items"
    var fills = newMailbox[Continuation]()
    var drains = newMailbox[Continuation]()
    var m = cores
    while m > 0:
      info "queue", m
      var q = newMailbox[ref int]()
      fills.send:
        whelp filler(q, m, N div cores)
      drains.send:
        whelp drainer(q, m, N div cores)
      queues.add q
      dec m
    var fillers = newPool(ContinuationRunner, fills, initialSize = cores)
    var drainers = newPool(ContinuationRunner, drains, initialSize = cores)
    join fillers
    info "all fillers complete"
    join drainers
    info "all drainers complete"
  let clock = (getTime() - now).inMilliseconds.float / 1000.0
  let rate = N.float / clock
  let perCore = rate / cores.float
  notice fmt"{cores:>2d}core = {clock:>10.4f}s, {rate:>10.0f}/sec, {perCore:>10.0f}/core; "

proc main =
  var cores = @[countProcessors() div 2]
  var N = N
  if paramCount() > 1:
    cores = @[parseInt paramStr(2)]
  else:
    notice "pass integer as second argument to set number of cores"
    notice "defaulting to ", cores
    discard
  if paramCount() > 0:
    N = parseInt paramStr(1)
  else:
    notice "pass integer as first argument to set test size"
    notice "defaulting to ", N
    discard
  for n in cores.items:
    attempt(N, n)

main()
