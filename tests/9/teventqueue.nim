import pkg/balls

import insideout/eventqueue

suite "event queue":
  block:
    ## init
    var eq: EventQueue
    check eq.isNil
    init eq
    check not eq.isNil
  block:
    ## auto-init
    var eq: EventQueue
    var events: array[1, epoll_event]
    eq.wait(events, 0.001)
