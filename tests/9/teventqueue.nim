import pkg/balls

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
