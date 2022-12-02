import pkg/balls

import insideout/semaphores

suite "semaphores":
  test "stupid things":
    var s: Semaphore
    initSemaphore(s, 2)
    check s.available == 2
    check s.isReady
    inc s
    check s.isReady
    check s.available == 3
    dec s; dec s; dec s;
    check s.available == 0
    check not s.isReady
    signal s
    check s.isReady
    check s.available == 1
    wait s
    check s.available == 0
    inc s
    withSemaphore s:
      discard
