import std/atomics
import std/os
import std/posix
import std/strformat
import std/strutils

import pkg/balls
import pkg/cps

import insideout/backlog
import insideout/mailboxes
import insideout/runtimes
import insideout/times
import insideout/valgrind


let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    1
  else:
    1000

let secs = 0.10           ## fail if the signal remains uncaught after `secs`
let delay =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    5
  else:
    1

type
  Server = ref object of Continuation
  Job = ref object

proc blocking(name: string; jobs: Mailbox[Job]) {.cps: Server.} =
  ## blocking receive
  debug name, " service began"
  var ts = secs.toTimeSpec
  var rem: TimeSpec
  let err = clock_nanosleep(CLOCK_MONOTONIC, 0, ts, rem)
  case err
  of 0:
    error name, " service time-out"
  else:
    let delta = ts - rem
    info fmt"{name} nanosleep: {strerror(errno)} after {delta}"
  coop()             # yield to the dispatcher so that it may halt gracefully
  discard recv jobs
  debug name, " service ended"

template tookLessThan(t: float; body: untyped): untyped =
  var a, b: TimeSpec
  check 0 == clock_gettime(CLOCK_MONOTONIC, a)
  body
  check 0 == clock_gettime(CLOCK_MONOTONIC, b)
  b = b - a
  let msg = $b & " seconds"
  if t < b.toFloat:
    fail msg

var jobs = newMailbox[Job]()

template blocked(name: string; body: untyped): untyped {.dirty.} =
  tookLessThan secs:
    notice "$# begin" % [ name ]
    var runtime {.inject.} = spawn: whelp blocking(name, jobs)
    info "$# unblock" % [ name ]
    sleep delay         # give the runtime a chance to enter the blocking state
    body                # perform the specified operations
    info "$# recover" % [ name ]
    join runtime        # wait for the runtime to shutdown
    notice "$# finish" % [ name ]

proc main() =
  var job: Job

  suite "blocking":
    setup:
      jobs.send Job()

    teardown:
      clear jobs

    block:
      ## halt
      blocked "[halt]":
        halt runtime
      if Received != jobs.tryRecv(job):
        fail "job should not have been consumed"

    block:
      ## interrupt
      blocked "[interrupt]":
        interrupt runtime
      if Received == jobs.tryRecv(job):
        fail "job should have been consumed"

    block:
      ## quit
      blocked "[quit]":
        signal(runtime, SIGQUIT)
        interrupt runtime
      if Received != jobs.tryRecv(job):
        fail "job should not have been consumed"

    block:
      ## cancel
      if isGrinding():
        skip "cancel test will fail grinds"
      blocked "[cancel]":
        cancel runtime
      if Received != jobs.tryRecv(job):
        fail "job should not have been consumed"

for i in 1..N:
  main()
