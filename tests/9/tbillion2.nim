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
    1_000_000_000

proc work() {.cps: Continuation.} =
  discard

proc filler(queue: Mailbox[Continuation]; m: int) {.cps: Continuation.} =
  var m = m
  while m > 0:
    queue.send: whelp work()
    dec m
  raise ValueError.newException "done"

proc attempt(N: Positive; cores: int = countProcessors()) =
  var queues: seq[Mailbox[Continuation]]
  block:
    echo "filling queues with ", N, " work items"
    var fills = newMailbox[Continuation]()
    var m = cores
    while m > 0:
      var q = newMailbox[Continuation]()
      fills.send:
        whelp q.filler(N div cores)
      queues.add q
      dec m
    var fillers = newPool(ContinuationWaiter, fills, initialSize = cores)
    for filler in fillers.mitems:
      join filler
    shutdown fillers
  block:
    var pool: Pool[Continuation, Continuation]
    for queue in queues.mitems:
      pause queue
      pool.spawn(ContinuationWaiter, queue)
    let now = getTime()
    for queue in queues.mitems:
      resume queue
    for queue in queues.mitems:
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
