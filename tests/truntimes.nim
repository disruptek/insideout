import std/os

import pkg/balls

import pkg/cps

import insideout/runtimes
import insideout/mailboxes

type
  RS = ref string

proc `==`(a: RS; b: string): bool = a[] == b
proc `==`(a, b: RS): bool = a[] == b[]
proc `$`(rs: RS): string {.used.} = rs[]
proc rs(s: string): RS =
  result = new string
  result[] = s

type
  Server = ref object of Continuation

proc service(mail: Mailbox[RS]) {.cps: Server.} =
  checkpoint "service runs"
  sleep 100
  checkpoint "service exits"

proc main =

  const Service = whelp service
  var runtime: Runtime[Server, RS]

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
      check other == runtime
    block:
      ## run some time
      let mail = newMailbox[RS]()
      runtime = Service.spawn(mail)
      var other = runtime
      sleep 50
      check other.state == Running
      pinToCpu(other, 0)
      check runtime.ran
      check runtime.running
      check runtime.mailbox == mail
      sleep 100
      check other.state == Stopping
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
