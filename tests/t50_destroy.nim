import pkg/cps
import insideout
import insideout/runtimes
import insideout/backlog

const N = 3

proc foo(i: int) {.cps: Continuation.} =
  ## do something... or rather, nothing
  debug "nothing to do #", i

proc main() =
  info "mailbox"
  block:
    var mailbox = newMailbox[Continuation]()

  info "runtime"
  block:
    var mailbox = newMailbox[Continuation]()
    var runtime = ContinuationRunner.spawn(mailbox)
    info runtime
    mailbox.send:
      whelp foo(42)
    join runtime

  info "empty pool"
  block:
    var mailbox = newMailbox[Continuation]()
    var pool {.used.} = newPool(ContinuationWaiter, mailbox, 0)

  info "full pool with joins"
  block:
    var mailbox = newMailbox[Continuation]()
    var pool = newPool(ContinuationRunner, mailbox, N)
    for runtime in pool.mitems:
      info runtime
    for i in 1..N:
      mailbox.send:
        whelp foo(i)
    for runtime in pool.mitems:
      info runtime
      join runtime

  when false:
    info "full pool with cancellations"
    block:
      var mailbox = newMailbox[Continuation]()
      var pool = newPool(ContinuationRunner, mailbox, N)
      for runtime in pool.mitems:
        info runtime
        cancel runtime
        join runtime

main()
