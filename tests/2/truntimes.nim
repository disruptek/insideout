import std/atomics
import std/os
import std/strformat

#import pkg/balls
import pkg/cps

import pkg/insideout/runtimes
import pkg/insideout/mailboxes

type
  Server = ref object of Continuation
  Job = ref object
    flag: Atomic[bool]

proc service(jobs: Mailbox[Job]) {.cps: Server.} =
  debugEcho "service runs"
  var job = recv jobs
  debugEcho "service receives flag: " & $job.flag
  store(job.flag, not load(job.flag))
  debugEcho "service toggling flag: " & $job.flag
  debugEcho "service exits"

const Service = whelp service

proc main() =

  block balls_breaks_destructor_semantics:
    block:
      ## run some time
      let jobs = newMailbox[Job]()
      var runtime: Runtime[Server, Job] = Service.spawn(jobs)
      var other = runtime
      doAssert other.state in {Launching, Running}
      doAssert other == runtime
      pinToCpu(other, 0)
      sleep 100
      doAssert runtime.state >= Running
      doAssert runtime.mailbox == jobs
      var job = Job()
      store(job.flag, true)
      jobs.send job
      doAssert runtime.state >= Running
      join runtime
      doAssert runtime.state == Stopped
    block:
      ## destructors
      let jobs = newMailbox[Job]()
      var runtime = Service.spawn(jobs)
      cancel runtime
      sleep 100
      join runtime
      doAssert runtime.owners == 1, "expected 1 owner; it's " & $runtime.owners

when isMainModule:
  main()
