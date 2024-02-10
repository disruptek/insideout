import std/strutils

import pkg/cps

import insideout/runtimes
import insideout/mailboxes

proc server(jobs: Mailbox[Continuation]) {.cps: Continuation.} =
  var job = recv jobs
  discard trampoline(move job)

proc sing(message: string) {.cps: Continuation.} =
  echo message

proc shout(message: string) {.cps: Continuation.} =
  echo message.toUpper

const Factory = whelp server

proc main =
  var queue = newMailbox[Continuation]()
  queue.send:
    whelp shout("i said, 'hello, world!'")

  queue.send:
    whelp sing("hello, world!")

  var service = spawn(Factory, queue)
  join service

main()
