import std/os

import pkg/cps
import insideout
import insideout/runtimes
import insideout/backlog

proc helloWorld() {.cps: Continuation.} =
  notice "hello world"

proc main() =
  info "mailbox"
  block:
    let mailbox = newMailbox[Continuation]()

  info "pool"
  block:
    let mailbox = newMailbox[Continuation]()
    var pool {.used.} = newPool(ContinuationWaiter, mailbox, 0)

  info "runtime"
  block:
    let mailbox = newMailbox[Continuation]()
    var pool {.used.} = newPool(ContinuationWaiter, mailbox, 1)
    for runtime in pool.mitems:
      info runtime
      while runtime.state != Running:
        sleep 1
      mailbox.send:
        whelp helloWorld()
      info runtime
      cancel runtime
      join runtime
      info runtime

  when false:

    echo "continuation"
    block:
      let mailbox = newMailbox[Continuation]()
      var pool {.used.} = newPool(ContinuationWaiter, mailbox, 1)
      mailbox.send:
        whelp helloWorld()

main()
