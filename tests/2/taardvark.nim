import std/os
import std/strutils

import pkg/cps

import pkg/insideout/runtimes
import pkg/insideout/mailboxes

type
  Service = Runtime[Continuation, Continuation]

proc server(jobs: Mailbox[Continuation]) {.cps: Continuation.} =
  var job = recv jobs
  discard trampoline job

proc sing(message: string) {.cps: Continuation.} =
  echo message

proc shout(message: string) {.cps: Continuation.} =
  echo message.toUpper

const Factory = whelp server

proc main =
  block:
    var queue = newMailbox[Continuation]()
    queue.send:
      whelp sing("hello, world!")

    queue.send:
      whelp shout("i said, 'hello, world!'")

    block:
      var service = spawn(Factory, queue)
      # give the service a chance to process the message
      sleep 10
      # cancel the service
      cancel service
      # give the service a chance to shutdown
      sleep 10
  # give the service a chance to crash
  sleep 10

main()
