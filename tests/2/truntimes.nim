import std/atomics
import std/os
import std/strformat

import pkg/balls
import pkg/cps

import pkg/insideout/runtimes
import pkg/insideout/mailboxes

type
  Server = ref object of Continuation
  Job = ref object
    flag: Atomic[bool]

proc cooperate(c: Continuation): Continuation {.cpsMagic.} = c

proc service(jobs: Mailbox[Job]) {.cps: Server.} =
  debugEcho "service runs"
  while true:
    var job: Job
    case jobs.tryRecv(job)
    of Received:
      debugEcho "service receives flag: " & $job.flag
      store(job.flag, not load(job.flag))
      debugEcho "service toggling flag: " & $job.flag
    of Unreadable:
      break
    else:
      if not jobs.waitForPoppable():
        break
    cooperate()
  debugEcho "service exits"

const Service = whelp service

proc main() =

  block balls_breaks_destructor_semantics:
    block:
      echo "\n\ntesting cancellation"
      let jobs = newMailbox[Job]()
      echo "spawn"
      var runtime = Service.spawn(jobs)
      echo "cancel"
      cancel runtime
      echo "join"
      join runtime
    block:
      echo "run some time"
      let jobs = newMailbox[Job]()
      var runtime: Runtime[Server, Job] = Service.spawn(jobs)
      var other = runtime
      doAssert other.state in {Launching, Running}
      doAssert other == runtime
      pinToCpu(other, 0)
      #doAssert runtime.state >= Running
      doAssert runtime.mailbox == jobs
      var job = Job()
      store(job.flag, true)
      jobs.send job
      jobs.disablePush()
      join runtime
      when false:
        doAssert runtime.state == Stopped
        doAssert runtime.owners == 2, "expected 2 owners; it's " & $runtime.owners
        reset other
        doAssert runtime.owners == 1, "expected 1 owner; it's " & $runtime.owners

when isMainModule:
  main()
