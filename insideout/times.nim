import std/macros
import std/math
import std/posix
import std/strformat

import insideout/importer

macro timeh(n: untyped): untyped = importer(n, newLit"<time.h>")

let CLOCK_REALTIME_COARSE* {.timeh.}: ClockId
let CLOCK_MONOTONIC_COARSE* {.timeh.}: ClockId

export ClockId, CLOCK_MONOTONIC, CLOCK_REALTIME,
       CLOCK_THREAD_CPUTIME_ID, CLOCK_PROCESS_CPUTIME_ID

proc `$`*(ts: TimeSpec): string =
  var f = ts.tv_sec.float + ts.tv_nsec / 1_000_000_000
  result = fmt"{f:>10.6f}"

proc getTimeSpec*(clock: ClockId): TimeSpec =
  if 0 != clock_gettime(clock, result):
    raise OSError.newException "clock_gettime() failed"

proc toTimeSpec*(timeout: float): TimeSpec =
  assert timeout >= 0.0
  result.tv_sec = Time timeout.floor
  result.tv_nsec = clong((timeout - result.tv_sec.float) * 1_000_000_000)

proc `+`*(a, b: TimeSpec): TimeSpec =
  result.tv_sec = Time(a.tv_sec.clong + b.tv_sec.clong)
  result.tv_nsec = a.tv_nsec + b.tv_nsec
  if result.tv_nsec >= 1_000_000_000:
    result.tv_sec = Time(result.tv_sec.clong + 1)
    result.tv_nsec -= 1_000_000_000
