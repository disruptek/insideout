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

  var runtime: Runtime[Server, Job]

  block balls_breaks_destructor_semantics:
    block:
      ## basics
      doAssert runtime.isNil
      doAssert runtime.owners == 0
      #new runtime
      #doAssert not runtime.isNil
      #doAssert runtime.owners == 1
      #doAssert runtime.state == Uninitialized
      #new runtime
      #doAssert runtime.owners == 1
      #var other = runtime
      #doAssert runtime.owners == 2
      #doAssert other.owners == 2
      #doAssert other.state == Uninitialized
      #doAssert not other.ran
      #doAssert not runtime.ran
    block:
      ## run some time
      let jobs = newMailbox[Job]()
      runtime = Service.spawn(jobs)
      var other = runtime
      doAssert other.state in {Launching, Running}
      doAssert other == runtime
      pinToCpu(other, 0)
      sleep 10
      doAssert runtime.state in {Running, Stopping, Stopped}
      #doAssert runtime.running
      doAssert runtime.mailbox == jobs
      var job = Job()
      store(job.flag, true)
      #var held = job
      jobs.send job
      jobs.disablePush()
      sleep 100
      #doAssert held.value == false
      #doAssert fmt"state mismatch: {other.state}":
      let was = other.state
      if was notin {Stopping, Stopped}:
        doAssert false, "was was " & $was
      #doAssert other.state in {Stopping, Stopped}
      #doAssert not runtime.running
      #join runtime
      doAssert runtime.state == Stopped
      #doAssert not runtime.running
      #doAssert runtime.ran
    block:
      ## destructors
      doAssert runtime.owners == 1, "expected 1 owner; it's " & $runtime.owners

when isMainModule:
  main()
