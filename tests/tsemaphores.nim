import insideout/semaphores

proc main =
  var s: Semaphore
  initSemaphore(s, 2)
  doAssert s.available == 2
  doAssert s.isReady
  inc s
  doAssert s.isReady
  doAssert s.available == 3
  dec s; dec s; dec s;
  doAssert s.available == 0
  doAssert not s.isReady
  signal s
  doAssert s.isReady
  doAssert s.available == 1
  wait s
  doAssert s.available == 0
  inc s
  withSemaphore s:
    discard

when isMainModule:
  main()
