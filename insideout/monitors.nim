import std/macros
import std/posix

import pkg/cps

import insideout/spec
import insideout/runtimes
import insideout/times
export toTimeSpec, nanosleep, errno, TimeSpec, EINTR

proc sleep*(timeout: float) {.cps: Continuation.} =
  ## sleep for `timeout` seconds using CLOCK_BOOTTIME; ie.
  ## reflecting both continuation and system suspensions
  template clock: untyped = CLOCK_BOOTTIME
  var zzz = getTimeSpec(clock) + timeout.toTimeSpec
  var rem: TimeSpec
  while -1 == clock_nanosleep(clock, TIMER_ABSTIME, zzz, rem):
    if errno == EINTR:
      zzz = rem
      coop()
    else:
      break

proc halter*(runtime: Runtime; timeout: float) {.cps: Continuation.} =
  ## halt `runtime` after `timeout` seconds
  sleep timeout
  halt runtime
