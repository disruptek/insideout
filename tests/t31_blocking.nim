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
    1

const secs = 0.10
const delay = 0

type
  Server = ref object of Continuation
  Job = ref object

proc blocking(name: string; jobs: Mailbox[Job]) {.cps: Server.} =
  ## blocking receive
  debug name, " service began"
  var ts = toTimeSpec: secs
  var rem: TimeSpec
  let err = clock_nanosleep(CLOCK_MONOTONIC, 0, ts, rem)
  case err
  of 0:
    error name, " service time-out"
  else:
    let delta = ts - rem
    info fmt"{name} nanosleep: {strerror(errno)} after {delta}"
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

template blocked(name: string; body: untyped): untyped =
  tookLessThan secs:
    var jobs {.inject.} = newMailbox[Job]()
    notice "$# begin" % [ name ]
    var runtime {.inject.} = spawn: whelp blocking(name, jobs)
    sleep delay
    info "$# unblock" % [ name ]
    body
    jobs.send Job()
    info "$# recover" % [ name ]
    join runtime
    notice "$# finish" % [ name ]

proc main() =

  suite "blocking":
    block:
      ## halt
      blocked "[halt]":
        halt runtime

    block:
      ## interrupt
      blocked "[interrupt]":
        interrupt runtime

    block:
      ## quit
      blocked "[quit]":
        signal(runtime, SIGQUIT)
        interrupt runtime

    block:
      ## cancel
      if isGrinding():
        skip "cancel test will fail grinds"
      blocked "[cancel]":
        cancel runtime

for i in 1..N:
  main()
