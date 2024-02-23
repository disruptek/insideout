import pkg/balls

import insideout/eventqueue

suite "event queue":
  block:
    ## init
    proc main =
      var eq: EventQueue
      var events: array[2, epoll_event]
      check eq.isNil
      check 0 == eq.wait(events, 0.001)
      check not eq.isNil
    main()
