import insideout/semaphores

proc main =
  var s: Semaphore
  initSemaphore(s, 2)
  doAssert s.available == 2
  inc s
  doAssert s.available == 3
  dec s; dec s; dec s;
  doAssert s.available == 0
  signal s
  doAssert s.available == 1
  wait s
  doAssert s.available == 0
  inc s
  withSemaphore s:
    discard

when isMainModule:
  main()
