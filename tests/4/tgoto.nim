import std/os

import pkg/cps
import pkg/insideout

proc visit(home, away: UnboundedFifo[Continuation]) {.cps: Continuation.} =
  echo "i am @ ", getThreadId()
  goto away
  echo "i am @ ", getThreadId()
  echo "leaving visit"

proc server(box: UnboundedFifo[Continuation]) {.cps: Continuation.} =
  while true:
    sleep 1000
    var visitor: Continuation
    var receipt: WardFlag = tryRecv(box, visitor)
    debugEcho receipt
    case receipt
    of Paused, Empty:
      if not waitForPoppable(box):
        break
    of Readable:
      break
    of Writable:
      discard trampoline(move visitor)
    else:
      discard
  echo "server exit"

const Service = whelp server

proc application(home: UnboundedFifo[Continuation]) {.cps: Continuation.} =
  echo "i am @ ", getThreadId()
  var away = newUnboundedFifo[Continuation]()
  var service = Service.spawn(away)
  visit(home, away)
  sleep 100
  echo "i am @ ", getThreadId()
  sleep 100
  echo "going home"
  goto home
  echo "i'm home"
  sleep 100
  echo "i am @ ", getThreadId()
  disablePush away
  echo "disabled push"
  sleep 100

  stop service
  echo "stopped service"
  sleep 100
  cancel service
  echo "cancelled service"
  sleep 100
  echo "exit application"

proc main =
  block:
    var home = newUnboundedFifo[Continuation]()
    var c = Continuation: whelp application(home)
    discard trampoline(move c)
    doAssert c.isNil
    echo "listening for app"
    sleep 2000
    c = recv home
    echo "got something"
    discard trampoline(move c)
    echo "application complete"
  echo "program exit"

when isMainModule:
  main()
