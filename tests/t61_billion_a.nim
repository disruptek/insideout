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
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding() or insideoutSafeMode:
    1_000_000
  else:
    100_000_000
let M = countProcessors()

proc work() {.cps: Continuation.} =
  discard

proc filler(queue: Mailbox[Continuation]; m: int) {.cps: Continuation.} =
  var m = m
  while m > 0:
    var c = whelp work()
    while Delivered != queue.trySend(Continuation c):
      discard
    dec m

proc attempt(N: Positive; cores: int = countProcessors()) =
  var queue = newMailbox[Continuation]()
  block:
    info "filling queue with ", N, " work items"
    var fills = newMailbox[Continuation]()
    var m = M
    while m > 0:
      fills.send:
        whelp queue.filler(N div M)
      dec m
    var fillers = newPool(ContinuationRunner, fills, initialSize = M)
    # don't join runtimes until they've all begun their filler
    fills.waitForEmpty()
  pause queue
  info "booting ", cores, " cores"
  var now: Time
  var clock: float
  block:
    var pool = newPool(ContinuationWaiter, queue, initialSize = cores)
    now = getTime()
    resume queue
    interrupt pool
    waitForEmpty queue
    clock = (getTime() - now).inMilliseconds.float / 1000.0
    halt pool
    closeWrite queue
    closeRead queue
  let rate = N.float / clock
  let perCore = rate / cores.float
  info fmt"{cores:>2d}core = {clock:>10.4f}s, {rate:>10.0f}/sec, {perCore:>10.0f}/core; "

proc main =
  var cores = @[countProcessors()]
  var N = N
  if paramCount() > 1:
    cores = @[parseInt paramStr(2)]
  else:
    notice "pass integer as second argument to set number of cores"
    notice "defaulting to ", cores
  if paramCount() > 0:
    N = parseInt paramStr(1)
  else:
    notice "pass integer as first argument to set test size"
    notice "defaulting to ", N
  for n in cores.items:
    attempt(N, n)

  # give the log a chance to output the stats
  sleep 10

main()
