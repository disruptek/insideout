import std/atomics

import pkg/cps
import pkg/balls

import insideout
import insideout/backlog
import insideout/monitors

const N = 3

proc foo(i: int) {.cps: Continuation.} =
  ## do something... or rather, nothing
  discard

makeHalter[Continuation, Continuation]()

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
      doAssert pool.count == N
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
      doAssert pool.count == N
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
      doAssert pool.count == N
      join pool
      doAssert pool.count == N
      clear pool
      doAssert pool.count == 0
    main()

  block:
    ## structured concurrency
    proc main() =
      let remote = newMailbox[Continuation]()
      block:
        var pool = newPool(ContinuationRunner, remote, initialSize = N)
        doAssert pool.count == N
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
      doAssert runtime.state == Running
      halter(runtime, 0.1)
      join runtime
    main()

  block:
    ## halt a runtime from another thread
    proc main() =
      let remote = newMailbox[Continuation]()
      var runtime = spawn(ContinuationWaiter, remote)
      doAssert runtime.state == Running
      var k = spawn: whelp halter(runtime, 0.1)
      doAssert k.state == Running
      join k
      join runtime
      doAssert runtime.state == Halted
    main()

when false:
  block:
    ## a cancelled pool performs a join as it exits scope
    proc main() =
      let remote = newMailbox[Continuation]()
      var pool = newPool(ContinuationWaiter, remote, initialSize = N)
      doAssert pool.count == N
      info "cancel pool: ", pool
      cancel pool
    main()

  block:
    ## cancel and join on a pool works
    proc main() =
      let remote = newMailbox[Continuation]()
      var pool = newPool(ContinuationWaiter, remote, initialSize = N)
      info "pool size: ", pool.count
      doAssert pool.count == N
      for runtime in pool.items:
        info runtime
      cancel pool
      info "join pool: ", pool
      join pool
    main()
