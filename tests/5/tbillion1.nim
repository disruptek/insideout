import std/atomics
import std/os
import std/osproc
import std/strutils
import std/strformat
import std/times

import pkg/cps

import insideout

let N =
  if getEnv"GITHUB_ACTIONS" == "true":
    10_000_000
  else:
    100_000
let M = countProcessors()

proc work() {.cps: Continuation.} =
  discard

proc filler(queue: UnboundedFifo[Continuation]; m: int) {.cps: Continuation.} =
  var m = m
  while m > 0:
    queue.send: whelp work()
    dec m
  raise ValueError.newException "done"

proc attempt(N: Positive; cores: int = countProcessors()) =
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
  var cores = @[countProcessors()]
  var N = N
  if paramCount() > 1:
    cores = @[parseInt paramStr(2)]
  else:
    echo "pass integer as second argument to set number of cores"
    echo "defaulting to ", cores
  if paramCount() > 0:
    N = parseInt paramStr(1)
  else:
    echo "pass integer as first argument to set test size"
    echo "defaulting to ", N
  for n in cores.items:
    attempt(N, n)

main()
