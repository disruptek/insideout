import insideout/cubby

proc main =
  var c: Cubby[int8]
  doAssert c.isEmpty
  c[] = 42
  doAssert not c.isEmpty
  doAssert c[] == 42
  c.blockingWrite(24)
  doAssert c.blockingRead() == 24
  doAssert not c.hasFlag
  c.enable
  doAssert c.hasFlag
  c.disable
  doAssert not c.hasFlag
  c.toggle
  doAssert c.hasFlag
  c.enable
  doAssert c.hasFlag
  c.toggle
  doAssert not c.hasFlag
  c.disable
  doAssert not c.hasFlag

main()
