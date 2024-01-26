import std/os

import pkg/cps
import insideout
import insideout/runtimes

proc helloWorld() {.cps: Continuation.} =
  discard

proc main() =
  echo "mailbox"
  block:
    let mailbox = newMailbox[Continuation]()

  echo "pool"
  block:
    let mailbox = newMailbox[Continuation]()
    var pool {.used.} = newPool(ContinuationWaiter, mailbox, 0)

  echo "runtime"
  block:
    let mailbox = newMailbox[Continuation]()
    var pool {.used.} = newPool(ContinuationWaiter, mailbox, 1)
    for runtime in pool.mitems:
      echo runtime
      while runtime.state != Running:
        sleep 1
      echo runtime
      cancel runtime
      mailbox.send:
        whelp helloWorld()
      while runtime.state != Stopped:
        sleep 1
      echo runtime

  when false:

    echo "continuation"
    block:
      let mailbox = newMailbox[Continuation]()
      var pool {.used.} = newPool(ContinuationWaiter, mailbox, 1)
      mailbox.send:
        whelp helloWorld()

main()
