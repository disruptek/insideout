import std/macros
import std/posix

import pkg/cps

import insideout/spec
import insideout/runtimes
import insideout/times
export toTimeSpec, nanosleep, errno, TimeSpec, EINTR

proc sleep*(timeout: float) {.cps: Continuation.} =
  var zzz = timeout.toTimeSpec
  var rem: TimeSpec
  while -1 == nanosleep(zzz, rem):
    if errno == EINTR:
      zzz = rem
      coop()
    else:
      break

template makeHalter*[A, B](): untyped =
  proc halter(runtime: Runtime[A, B]; timeout: float) {.cps: Continuation.} =
    sleep timeout
    halt runtime
    signal(runtime, SIGINT)
    join runtime
