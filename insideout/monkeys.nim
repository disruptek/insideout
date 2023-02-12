import std/posix

const
  insideoutSleepyMonkey* {.intdefine.} = 0

when insideoutSleepyMonkey == 0:
  template sleepyMonkey*(): untyped = discard
else:
  import std/random

  var r {.threadvar.}: Rand
  r = initRand()
  proc sleepyMonkey*() =
    var req = Timespec(tv_sec: 0.Time,
                       tv_nsec: r.rand(insideoutSleepyMonkey).clong)
    var rem: Timespec
    discard nanosleep(req, rem)

