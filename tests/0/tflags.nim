import pkg/insideout/atomic/flags

type
  Lamp = enum
    Red
    Blue
    Green
  AtomicLamp = AtomicFlags[uint32]

doAssert Red.toFlag == 1
doAssert Blue.toFlag == 2
doAssert Green.toFlag == 4
var x: AtomicLamp
doAssert not x.contains(Red) # notin x
doAssert (x |= Blue) == {}
doAssert Blue in x
doAssert (x |= Red) == {Blue}
doAssert (x ^= {Red, Green}) == {Red, Blue}
doAssert Green in x
doAssert (x |= {Red, Green}) == {Green, Blue}
doAssert (x ^= {Red}) == {Red, Green, Blue}
