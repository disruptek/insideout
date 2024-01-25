import std/os

import pkg/cps
import pkg/insideout

proc visit(home, away: UnboundedFifo[Continuation]) {.cps: Continuation.} =
  echo "i am @ ", getThreadId(), " (home)"
  goto away
  echo "i am @ ", getThreadId(), " (away)"
  echo "leaving visit"

proc server(box: UnboundedFifo[Continuation]) {.cps: Continuation.} =
  while true:
    var visitor: Continuation
    var receipt: WardFlag = tryRecv(box, visitor)
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
    doAssert visitor.isNil
  echo "server exit"

const Service = whelp server

proc application(home: UnboundedFifo[Continuation]) {.cps: Continuation.} =
  echo "i am @ ", getThreadId(), " (home)"
  var away = newUnboundedFifo[Continuation]()
  var service = Service.spawn(away)
  echo "i am @ ", getThreadId(), " (home)"
  visit(home, away)
  echo "i am @ ", getThreadId(), " (away)"
  echo "going home"
  goto home
  echo "i am @ ", getThreadId(), " (home)"
  disablePush away
  echo "disabled push"
  join service
  echo "exit application"

proc main =
  block:
    var home = newUnboundedFifo[Continuation]()
    var c = Continuation: whelp application(home)
    discard trampoline(move c)
    doAssert c.isNil
    echo "listening for app"
    c = recv home
    echo "got something"
    discard trampoline(move c)
    doAssert c.isNil
    echo "application complete"
  echo "program exit"

when isMainModule:
  main()
