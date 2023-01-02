import insideout/mailboxes

type
  RS = ref string

proc `==`(a: RS; b: string): bool = a[] == b
proc `==`(a, b: RS): bool = a[] == b[]
proc `$`(rs: RS): string {.used.} = rs[]
proc rs(s: string): RS =
  result = new string
  result[] = s

proc main =
  var box: Mailbox[RS]
  var bix: Mailbox[RS]
  var missing: Mailbox[RS]
  block balls_breaks_destructor_semantics:
    block:
      ## basics
      doAssert box.isNil
      try:
        box.assertInitialized
        raise Defect.newException "expected ValueError"
      except ValueError:
        discard
      doAssert box.owners == 0
      doAssert box == bix
      box = newMailbox[RS](2)
      box.assertInitialized
      doAssert box != bix
      doAssert box.owners == 1
      bix = box
      doAssert box.owners == 2
      bix.assertInitialized
      doAssert bix.owners == 2
    block:
      ## send A
      var message = rs"hello"
      box.send message
      doAssert box.len == 1
    block:
      ## recv B
      let message = bix.recv
      doAssert message == rs"hello"
      doAssert box.len == 0
    block:
      ## send B
      var message = rs"goodbye"
      bix.send message
      doAssert box.len == 1
    block:
      ## recv A
      let message = box.recv
      doAssert message != "peace"
      doAssert message == "goodbye"
      doAssert box.len == 0
    block:
      ## copy
      var bax = bix
      doAssert bax.owners == 3, "after copy"
      var message = rs"sup dawg"
      bax.send message
      doAssert bax.owners == 3, "after send"
      doAssert box.len == 1
    block:
      ## ownership
      doAssert bix.owners == 2
      let message = recv box
      doAssert message == "sup dawg"
      doAssert box.len == 0
    block:
      ## missing mailboxes
      doAssert missing == MissingMailbox
      doAssert missing.isNil
      doAssert MissingMailbox.isNil
    block:
      ## try modes
      var one = rs"one"
      var two = rs"two"
      var tres = rs"tres"
      doAssert box.len == 0
      doAssert box.trySend one
      doAssert box.len == 1
      doAssert box.trySend two
      doAssert box.len == 2
      doAssert not box.trySend tres
      doAssert box.len == 2
      var message: RS
      doAssert box.len == 2
      doAssert box.tryRecv(message)
      doAssert box.len == 1
      doAssert box.tryRecv(message)
      doAssert box.len == 0
      doAssert not box.tryRecv(message)
      doAssert box.len == 0
    block:
      ## destructors
      doAssert box.owners == 2, "expected 2 owners; it's " & $box.owners
      bix = missing
      doAssert box.owners == 1, "expected 1 owner; it's " & $box.owners

when isMainModule:
  main()
