## macOS cps `sleep` test
##
## On Linux `sleep` is backed by a timerfd; macOS has no timerfd, so it is
## emulated with a fd-less one-shot `EVFILT_TIMER` registered on the kqueue
## (see `suspendTimer`/`sleep` in insideout/eventqueue.nim).  This test
## asserts that a continuation which sleeps for 0.5s is genuinely suspended
## -- at least ~0.4s elapses -- before the event queue resumes it.
##
## Guarded to Darwin/BSD: it specifically drives the kqueue EVFILT_TIMER
## path; the timerfd path is covered by t90_eventqueue.nim.
import std/atomics
import std/os
import std/unittest
import std/times
template info*(arg: string) = echo "[INFO] ", arg
template debug*(arg: string) = discard
import pkg/cps
import insideout/runtimes
import insideout/eventqueue
import insideout/valgrind
import insideout/atomic/flags

when defined(macosx) or defined(darwin) or defined(bsd):
  type Server = ref object of Continuation
  var ended: Atomic[bool]
  var startTime, endTime: float

  proc sleeper(eq: EventQueue) {.cps: Server.} =
    startTime = epochTime()
    sleep(eq, 0.5)
    endTime = epochTime()
    ended.store(true)

  const Sleeper = whelp sleeper

  suite "sleep (macOS)":
    test "a cps sleep suspends for the requested duration":
      var eq: EventQueue
      init eq
      let runtime = spawn(Sleeper.call(eq))
      var events: array[1, EventInfo]
      let n = eq.wait(events, timeout = 2.0)
      if n > 0:
        eq.run(events, n)
        eq.pruneOneShots(events, n)
      check ended.load()
      if ended.load():
        check endTime - startTime >= 0.4
      halt runtime
      join runtime
