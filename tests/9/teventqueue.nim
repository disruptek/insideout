import std/atomics

import pkg/balls

import pkg/cps

import insideout
import insideout/eventqueue

suite "event queue":
  block:
    ## init, destroy
    proc main =
      withNewEventQueue eq:
        check not eq.isNil
        var events: array[2, epoll_event]
        check 0 == eq.wait(events, 0.001)
    main()

  block:
    ## init, deinit, deinit
    proc main =
      withNewEventQueue eq:
        deinit eq
    main()

  block:
    ## event queue passing
    # pass the queue into a continuation,
    # run it on another thread where it registers a timer,
    # use the queue to wait for an event in the original thread, and
    # run the continuation.
    var zzz: Atomic[int]
    proc snooze(eq: EventQueue) {.cps: Continuation.} =
      eq.sleep(0.2)
      zzz.store(1)
      checkpoint "yawn"

    proc main =
      withNewEventQueue eq:
        var runtime = spawn: whelp snooze(eq)
        join runtime
        var events: array[1, epoll_event]
        let n = eq.wait(events)
        if n > 0:
          eq.run(events, n)
          check 1 == zzz.load
          eq.pruneOneShots(events, n)
    main()
