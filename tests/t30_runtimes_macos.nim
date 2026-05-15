## macOS runtime spawn/join smoke test
##
## Verifies that a runtime can be spawned, receive one message over a
## mailbox, and be joined cleanly on macOS.  This exercises the Darwin
## thread-creation path in insideout/runtimes.nim -- macOS has no
## `pthread_attr_setsigmask_np`, so the signal mask is instead applied to
## the dispatcher thread via `pthread_sigmask` -- together with the
## kqueue-backed event queue.
##
## Guarded to Darwin/BSD: generic spawn/join behaviour is already covered
## by t30_runtimes.nim; this file exists to keep the macOS port from
## regressing and would only add noise on other platforms.
import std/atomics
import std/os
import std/unittest
template info*(arg: string) = echo "[INFO] ", arg
template debug*(arg: string) = discard
import pkg/cps
import insideout/runtimes
import insideout/mailboxes
import insideout/valgrind
import insideout/atomic/flags

when defined(macosx) or defined(darwin) or defined(bsd):
  type
    Server = ref object of Continuation
    Job = ref object

  var began, recvd, ended: Atomic[bool]

  proc unblocking(jobs: Mailbox[Job]) {.cps: Server.} =
    coop()
    began.store(true)
    var job: Job
    while true:
      case jobs.tryRecv(job)
      of Received:
        recvd.store(true)
      else:
        if not jobs.waitForPoppable: break
    ended.store(true)

  const Unblocking = whelp unblocking

  suite "runtimes (macOS)":
    test "a spawned runtime receives a job and joins cleanly":
      let jobs = newMailbox[Job]()
      var runtime = Unblocking.spawn(jobs)
      var job = Job()
      while Delivered != jobs.trySend(job): discard
      jobs.closeWrite()
      join runtime
      check ended.load
      check recvd.load
