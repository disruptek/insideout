import std/atomics
import std/os
import std/osproc
import std/strutils
import std/strformat
import std/times

import pkg/cps

import insideout
import insideout/valgrind
#import insideout/backlog

let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    10_000
  else:
    100_000

proc drainer(queue: Mailbox[ref int]; n: int) {.cps: Continuation.} =
  var m = n
  while m > 0:
    var i = queue.recv
    assert i[] <= n
    dec m

proc filler(queue: Mailbox[ref int]; m: int) {.cps: Continuation.} =
  var m = m
  while m > 0:
    var i: ref int
    new i
    i[] = m
    queue.send: i
    dec m

proc attempt(N: Positive; cores: int = countProcessors()) =
  let now = getTime()
  var queues: seq[Mailbox[ref int]]
  block:
    #info "filling queues with ", N, " work items"
    var fills = newMailbox[Continuation]()
    var drains = newMailbox[Continuation]()
    var m = cores
    while m > 0:
      var q = newMailbox[ref int]()
      fills.send:
        whelp q.filler(N div cores)
      drains.send:
        whelp q.drainer(N div cores)
      queues.add q
      dec m
    var fillers = newPool(ContinuationRunner, fills, initialSize = cores)
    var drainers = newPool(ContinuationRunner, drains, initialSize = cores)
  let clock = (getTime() - now).inMilliseconds.float / 1000.0
  let rate = N.float / clock
  let perCore = rate / cores.float
  #notice fmt"{cores:>2d}core = {clock:>10.4f}s, {rate:>10.0f}/sec, {perCore:>10.0f}/core; "

proc main =
  var cores = @[countProcessors()]
  var N = N
  if paramCount() > 1:
    cores = @[parseInt paramStr(2)]
  else:
    #notice "pass integer as second argument to set number of cores"
    #notice "defaulting to ", cores
    discard
  if paramCount() > 0:
    N = parseInt paramStr(1)
  else:
    #notice "pass integer as first argument to set test size"
    #notice "defaulting to ", N
    discard
  for n in cores.items:
    attempt(N, n)

main()
