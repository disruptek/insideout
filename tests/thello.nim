import pkg/cps
import pkg/insideout

proc greet(source: int) {.cps: Continuation.} =
  ## say hello!
  echo "hello to thread ", source, " from thread ", getThreadId()

proc main() =
  # a place where we can move any Continuation
  let remote = newMailbox[Continuation]()

  # a thread pool that consumes the mailbox
  # using a generic Continuation running service
  let pool = newPool(ContinuationWaiter, remote)

  # run a new Continuation somewhere else
  remote.send:
    whelp greet(getThreadId())

main()
