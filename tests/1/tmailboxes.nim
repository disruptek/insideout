import pkg/insideout/mailboxes

type
  RS = ref string

proc `==`(a: RS; b: string): bool = a[] == b
proc `==`(a, b: RS): bool =
  (a.isNil and b.isNil) or (not a.isNil and not b.isNil and a[] == b[])
proc `$`(rs: RS): string {.used.} = rs[]
proc rs(s: string): RS =
  result = new string
  result[] = s

proc check(expr: bool; s: string) =
  if expr:
    debugEcho s
  else:
    raise AssertionDefect.newException "rip"

template check(expr: untyped): untyped =
  check(expr, "ok")

template trySendSuccess[T](box: Mailbox[T]; message: T): untyped =
  box.trySend(message) == Readable

template tryRecvSuccess[T](box: Mailbox[T]; message: T): untyped =
  box.tryRecv(message) == Writable

proc main =
  var receipt: RS
  block balls_breaks_destructor_semantics:
    block:
      echo "basic unbounded"
      var box = newMailbox[RS]()
      var bix = box
      check not box.isNil
      check box.owners == 2
      check box == bix
      check not bix.isNil
    block:
      echo "basic bounded"
      var box = newMailbox[RS](2)
      var bix = newMailbox[RS](2)
      check box != bix
      check box.owners == 1
      bix = box
      check box.owners == 2
      check not bix.isNil
      check bix.owners == 2
    block:
      echo "send A"
      var box = newMailbox[RS]()
      var message = rs"hello"
      box.send message
    block:
      echo "recv B"
      var box = newMailbox[RS]()
      var message = rs"hello"
      box.send message
      message = rs"unlikely"
      var bix = box
      check not box.isEmpty
      message = bix.recv
      check message == rs"hello"
      check Empty == tryRecv(box, receipt)
    block:
      echo "recv A"
      var message: RS
      var box = newMailbox[RS]()
      box.send rs"hello"
      box.send rs"goodbye"
      message = box.recv
      message = box.recv
      check message != "peace"
      check message == "goodbye"
      check Empty == tryRecv(box, receipt)
    block:
      echo "try modes"
      var box = newMailbox[RS](2)
      var one = rs"one"
      var two = rs"two"
      var tres = rs"tres"
      check box.trySendSuccess(one)
      check box.trySendSuccess(two)
      check not box.trySendSuccess(tres)
      var message: RS
      check box.tryRecvSuccess(message)
      check box.tryRecvSuccess(message)
      check not box.tryRecvSuccess(message)
    block:
      echo "destructors"
      var box = newMailbox[RS]()
      var bix = box
      check box.owners == 2, "expected 2 owners; it's " & $box.owners
      bix = newMailbox[RS]()
      check box.owners == 1, "expected 1 owner; it's " & $box.owners

when isMainModule:
  main()
