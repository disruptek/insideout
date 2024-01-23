import pkg/cps
import pkg/insideout

import std/atomics
import std/os

var hellos: Atomic[int]
var goodbyes: Atomic[int]

const briefly = 5  # for valgrind

proc cooperate(c: Continuation): Continuation {.cpsMagic.} =
  c

proc greetThreadId(source: int) {.cps: Continuation.} =
  ## say hello!
  cooperate()
  echo "hello to thread ", source, " from thread ", getThreadId()
  discard fetchAdd(hellos, 1)
  sleep briefly
  cooperate()
  echo "goodbye from thread ", getThreadId()
  discard fetchAdd(goodbyes, 1)

proc greetEveryone() {.cps: Continuation.} =
  ## say hello!
  cooperate()
  echo "hello to everyone from thread ", getThreadId()
  discard fetchAdd(hellos, 1)
  sleep briefly
  cooperate()
  echo "goodbye from thread ", getThreadId()
  discard fetchAdd(goodbyes, 1)

proc main() =
  block:
    # a place where we can move any Continuation
    let remote = newMailbox[Continuation]()

    block:
      # a thread pool that consumes the mailbox
      # using a generic Continuation running service
      let concurrency = 1
      let pool {.used.} = newPool(ContinuationWaiter, remote, concurrency)

      # run a new Continuation somewhere else
      remote.send:
        whelp greetThreadId(getThreadId())

      # run a different one somewhere else
      remote.send:
        whelp greetEveryone()

      debugEcho "i sent them"
      disablePush remote
      debugEcho "disabled push"

      while 2 != load(hellos):
        sleep briefly
      echo "ending with goodbye count of ", load(goodbyes)
      debugEcho "pool ending; mailbox owners: ", remote.owners
    debugEcho "pool ended; mailbox owners: ", remote.owners
  debugEcho "mailbox gone?"

main()
