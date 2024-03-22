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

proc main =
  suite "linked runtimes":
    # we'll use a lock to impose a total order on the two runtimes
    var L: Lock
    initLock L
    var parent, kid: Runtime
    block:
      ## spawn; spawn; link
      withLock L:
        parent = spawn: whelp guard(addr L)
        kid = spawn: whelp child(addr L, "unhappy")
        link(parent, kid)
      join kid
      join parent
      check kid.flags && <<Halted
      check parent.flags && <<Halted

    block:
      ## spawn; spawnLink
      withLock L:
        parent = spawn: whelp guard(addr L)
        kid = parent.spawnLink: whelp child(addr L, "unhappy")
      join kid
      join parent
      check kid.flags && <<Halted
      check parent.flags && <<Halted

main()
