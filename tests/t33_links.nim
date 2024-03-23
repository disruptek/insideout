## linking two runtimes together causes a failure in one to
## propagate to the other.
import std/locks

import pkg/balls
import pkg/cps

import insideout/monitors
import insideout/runtimes
import insideout/atomic/flags

proc child(L: ptr Lock; s: string) {.cps: Continuation.} =
  withLock L[]: discard
  coop()
  raise ValueError.newException s

proc guard(L: ptr Lock) {.cps: Continuation.} =
  withLock L[]: discard
  coop()
  sleep 1.0
  fail "guard reached completion"

template linkTest(body: untyped): untyped =
  # we'll use a lock to impose a total order on the two runtimes
  var L {.inject.}: Lock
  var parent {.inject.}: Runtime
  var kid {.inject.}: Runtime
  initLock L
  defer: deinitLock L
  withLock L:
    body
  join kid
  join parent
  check kid.flags && <<Halted
  check parent.flags && <<Halted

proc main =
  suite "linked runtimes":
    block:
      ## spawn; spawn; link
      linkTest:
        parent = spawn: whelp guard(addr L)
        kid = spawn: whelp child(addr L, "unhappy")
        link(parent, kid)

    block:
      ## spawn; spawnLink
      linkTest:
        parent = spawn: whelp guard(addr L)
        kid = parent.spawnLink: whelp child(addr L, "unhappy")

main()
