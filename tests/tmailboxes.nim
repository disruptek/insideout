import pkg/balls

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
      check not box.isInitialized
      expect ValueError:
        box.assertInitialized
      check box.owners == 0
      check box == bix
      box = newMailbox[RS](2)
      box.assertInitialized
      check box.capacity == 2
      check box != bix
      check box.owners == 1
      bix = box
      check box.owners == 2
      bix.assertInitialized
      check bix.owners == 2
    block:
      ## send A
      var message = rs"hello"
      box.send message
      check box.len == 1
    block:
      ## recv B
      let message = bix.recv
      check message == rs"hello"
      check box.len == 0
    block:
      ## send B
      var message = rs"goodbye"
      bix.send message
      check box.len == 1
    block:
      ## recv A
      let message = box.recv
      check message != "peace"
      check message == "goodbye"
      check box.len == 0
    block:
      ## copy
      var bax = bix
      check bax.owners == 3, "after copy"
      var message = rs"sup dawg"
      bax.send message
      check bax.owners == 3, "after send"
      check box.len == 1
    block:
      ## ownership
      check bix.owners == 2
      let message = recv box
      check message == "sup dawg"
      check box.len == 0
    block:
      ## missing mailboxes
      check missing == MissingMailbox
      check not missing.isInitialized
      check not MissingMailbox.isInitialized
    block:
      ## try modes
      var one = rs"one"
      var two = rs"two"
      var tres = rs"tres"
      check box.len == 0
      check box.trySend one
      check box.len == 1
      check box.trySend two
      check box.len == 2
      check not box.trySend tres
      check box.len == 2
      var message: RS
      check box.len == 2
      check box.tryRecv(message)
      check box.len == 1
      check box.tryRecv(message)
      check box.len == 0
      check not box.tryRecv(message)
      check box.len == 0
    block:
      ## destructors
      check box.owners == 2, "expected 2 owners; it's " & $box.owners
      bix = missing
      check box.owners == 1, "expected 1 owner; it's " & $box.owners

when isMainModule:
  main()
