import pkg/cps
import pkg/insideout

type
  Query = ref object of Continuation  ## client
    y: int

proc setupQueryWith(c: Query; y: int): Query {.cpsMagic.} =
  c.y = y * 2
  result = c

proc value(c: Query): int {.cpsVoodoo.} = c.y

proc ask(x: int): int {.cps: Query.} =
  ## the "client"
  when compiles(continuation()):
    # cps inspector
    var c {.cps: [Query].} = continuation()
    echo "asking " & $x & " in " & $getThreadId()
    novelThread[Query]()
    c.y = x * 2
    result = x + c.y
    echo "recover " & $x & " in " & $getThreadId(), " as ", result
  else:
    # no cps inspector :-(
    setupQueryWith x
    echo "asking " & $x & " in " & $getThreadId()
    novelThread[Query]()
    result = x + value()
    echo "recover " & $x & " in " & $getThreadId(), " as ", result

proc application(): int {.cps: Continuation.} =
  let home = getThreadId()

  # submit some questions, etc.
  var i = 10
  while i > 0:
    result += ask i
    dec i

  # we're still at home
  doAssert home == getThreadId()

proc main =
  let was = application()
  doAssert was == 165, "result was " & $was & " and not 165"
  echo "application complete"

when isMainModule:
  main()
