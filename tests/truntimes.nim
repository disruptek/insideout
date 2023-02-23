import std/os
import std/strformat

import pkg/balls

import pkg/cps

import insideout/runtimes
import insideout/mailboxes
import insideout/semaphores
import insideout/atomic/refs

type
  Server = ref object of Continuation
  SharedSemaphore = AtomicRef[Semaphore]

proc main =
  var sem: SharedSemaphore
  new sem
  initSemaphore sem

  proc service(mail: Mailbox[SharedSemaphore]) {.cps: Server.} =
    checkpoint "service runs"
    var sem = recv mail
    wait sem
    checkpoint "service exits"

  const Service = whelp service
  var runtime: Runtime[Server, SharedSemaphore]

  block balls_breaks_destructor_semantics:
    block:
      ## basics
      check runtime.isNil
      check runtime.owners == 0
      check runtime.state == Uninitialized
      new runtime
      check not runtime.isNil
      check runtime.owners == 1
      check runtime.state == Uninitialized
      new runtime
      check runtime.owners == 1
      var other = runtime
      check runtime.owners == 2
      check other.owners == 2
      check other.state == Uninitialized
      check not other.ran
      check not runtime.ran
    block:
      ## run some time
      let mail = newMailbox[SharedSemaphore](1)
      runtime = Service.spawn(mail)
      var other = runtime
      check other.state in {Launching, Running}
      check other == runtime
      pinToCpu(other, 0)
      check runtime.ran
      check runtime.running
      check runtime.mailbox == mail
      mail.send sem
      signal sem
      sleep 100
      check sem.available == 0
      check fmt"state mismatch: {other.state}":
        other.state in {Stopping, Stopped}
      check not runtime.running
      join runtime
      check runtime.state == Stopped
      check not runtime.running
      check runtime.ran
    block:
      ## destructors
      check runtime.owners == 1, "expected 1 owner; it's " & $runtime.owners

when isMainModule:
  main()
