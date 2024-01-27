import std/atomics
import insideout/atomic/flags

type
  Lamp = enum
    Red
    Blue
    Green
  AtomicLamp = AtomicFlags16

static:
  doAssert <<Red == 1
doAssert <<{Red, Blue} == 3
var x: AtomicFlags16
store(x, <<{Green} + <<!{Red, Blue}, order = moSequentiallyConsistent)
doAssert <<Red notin x
x.toggle(Red)
doAssert <<Red in x
x.disable Blue
doAssert <<Blue notin x
doAssert <<!Blue in x
doAssert <<!Red notin x
x.enable Blue
doAssert <<Blue in x
x.enable Green
doAssert <<Green in x
