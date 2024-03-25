import std/macros
import std/posix

import pkg/cps

import insideout/spec
import insideout/runtimes
import insideout/times
export toTimeSpec, nanosleep, errno, TimeSpec, EINTR

proc sleep*(timeout: float) {.cps: Continuation.} =
  {.warning: "FIXME: use absolute whatfer suspension".}
  var zzz = timeout.toTimeSpec
  var rem: TimeSpec
  while -1 == nanosleep(zzz, rem):
    if errno == EINTR:
      zzz = rem
      coop()
    else:
      break

proc halter*(runtime: Runtime; timeout: float) {.cps: Continuation.} =
  sleep timeout
  halt runtime
  interrupt runtime
  join runtime
