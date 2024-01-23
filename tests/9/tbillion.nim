import std/atomics
import std/os
import std/osproc
import std/strformat
import std/times

import pkg/cps

import insideout

const N = 1_000_000_000
const M = 25

proc work() {.cps: Continuation.} =
  discard

proc filler(queue: Mailbox[Continuation]; m: int) {.cps: Continuation.} =
  var m = m
  while m > 0:
    queue.send: whelp work()
    dec m
  raise ValueError.newException "done"

proc attempt(cores: int = countProcessors()) =
  var queue = newMailbox[Continuation]()
  block:
    echo "filling queue with ", N, " work items"
    var fills = newMailbox[Continuation]()
    var m = M
    while m > 0:
      fills.send:
        whelp queue.filler(N div M)
      dec m
    var fillers = newPool(ContinuationWaiter, fills, initialSize = M)
    for filler in fillers.mitems:
      join filler
    #waitForFull queue
    shutdown fillers
  block:
    pause queue
    var pool = newPool(ContinuationWaiter, queue, initialSize = cores)
    let now = getTime()
    resume queue
    waitForEmpty queue
    let clock = (getTime() - now).inMilliseconds.float / 1000.0
    let rate = N.float / clock
    let perCore = rate / cores.float
    echo fmt"{cores:>2d}core = {clock:>10.4f}s, {rate:>10.0f}/sec, {perCore:>10.0f}/core; "
    shutdown pool

proc main =
  #var cores = @[32, 24, 20, 16, 12, 10, 8, 7, 6, 5, 4, 3, 2, 1]
  #var cores = @[32, 16, 8, 4, 2, 1]
  var cores = @[16]
  for n in cores.items:
    attempt n

main()
