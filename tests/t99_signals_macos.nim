## macOS signal-handling test
##
## macOS has no signalfd; insideout emulates it with a dedicated signal
## thread that waits on `EVFILT_SIGNAL` and forwards each caught signal
## number through a pipe whose read end behaves like a signalfd (see
## `initSignalFd`/`macOSSignalThread` in insideout/eventqueue.nim).  This
## test blocks SIGTERM in the calling thread, spawns a runtime, raises
## SIGTERM at the process, and asserts the runtime observes it and reaches
## the Teardown state.
##
## Guarded to Darwin/BSD: it exercises the signal-pipe emulation path,
## which has no counterpart in the Linux signalfd build.
import std/atomics
import std/os
import std/unittest
import std/posix
template info*(arg: string) = echo "[INFO] ", arg
template debug*(arg: string) = discard
import pkg/cps
import insideout/runtimes
import insideout/eventqueue
import insideout/valgrind
import insideout/atomic/flags

when defined(macosx) or defined(darwin) or defined(bsd):
  type Server = ref object of Continuation
  proc service() {.cps: Server.} =
    while true: coop()

  const Service = whelp service

  suite "signals (macOS)":
    test "a runtime halts when the process receives SIGTERM":
      var mask: Sigset
      discard sigemptyset(mask)
      discard sigaddset(mask, SIGTERM)
      var oldMask: Sigset
      discard pthread_sigmask(SIG_BLOCK, mask, oldMask)
      let runtime = spawn(Service.call())
      os.sleep(100)
      discard posix.kill(posix.getpid(), SIGTERM)
      var finished = false
      for i in 1..20:
        if runtime.flags && <<Teardown:
          finished = true
          break
        os.sleep(100)
      check finished
