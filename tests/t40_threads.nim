import std/atomics

import pkg/cps
import pkg/balls

import insideout
import insideout/backlog
import insideout/monitors
import insideout/atomic/flags

const N = 3

proc foo(i: int) {.cps: Continuation.} =
  ## do something... or rather, nothing
  discard

suite "runtimes + mailboxes + pools":
  block:
    ## manual join on a pool works
    proc main() =
      let remote = newMailbox[Continuation]()
      for i in 1..N:
        info "send ", i
        remote.send:
          whelp foo(i)
      info "close write"
      closeWrite remote
      var pool = newPool(ContinuationRunner, remote, initialSize = N)
      info "pool size: ", pool.count
      check pool.count == N
      info "pool size: ", pool.count
      for runtime in pool.items:
        info runtime
      info "join pool: ", pool
      join pool
    main()

  block:
    ## a pool performs a join as it exits scope
    proc main() =
      let remote = newMailbox[Continuation]()
      for i in 1..N:
        info "send ", i
        remote.send:
          whelp foo(i)
      closeWrite remote
      var pool = newPool(ContinuationRunner, remote, initialSize = N)
      check pool.count == N
    main()

  block:
    ## halts take effect in the main loop
    proc main() =
      let remote = newMailbox[Continuation]()
      var pool = newPool(ContinuationRunner, remote, initialSize = N)
      halt pool
      for i in 1..N:
        info "send ", i
        remote.send:
          whelp foo(i)
      closeWrite remote
      check pool.count == N
      join pool
      check pool.count == N
      clear pool
      check pool.count == 0
    main()

  block:
    ## structured concurrency
    proc main() =
      let remote = newMailbox[Continuation]()
      block:
        var pool = newPool(ContinuationRunner, remote, initialSize = N)
        check pool.count == N
        for i in 1..N:
          info "send ", i
          remote.send:
            whelp foo(i)
        info "might join"
    main()

  block:
    ## gracefully halt a blocked runtime
    proc main() =
      let remote = newMailbox[Continuation]()
      var runtime = spawn(ContinuationWaiter, remote)
      check runtime.flags && <<!Boot
      halter(runtime, 0.1)
    main()

  block:
    ## halt a runtime from another thread
    proc main() =
      let remote = newMailbox[Continuation]()
      var runtime = spawn(ContinuationWaiter, remote)
      check runtime.flags && <<!Boot
      var k = spawn: whelp halter(runtime, 0.1)
      check k.flags && <<!Boot
      join k
      join runtime
      check runtime.flags && <<Teardown
    main()

  block:
    ## cancel and join on a pool works
    proc main() =
      let remote = newMailbox[Continuation]()
      var pool = newPool(ContinuationWaiter, remote, initialSize = N)
      info "pool size: ", pool.count
      check pool.count == N
      for runtime in pool.items:
        info runtime
      cancel pool
      info "join pool: ", pool
      join pool
    main()

  block:
    ## a cancelled pool performs a join as it exits scope
    proc main() =
      let remote = newMailbox[Continuation]()
      var pool = newPool(ContinuationWaiter, remote, initialSize = N)
      check pool.count == N
      info "cancel pool: ", pool
      cancel pool
    main()
