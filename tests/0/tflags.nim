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
x.enable(Red)
doAssert <<Red in x
x.disable Blue
doAssert <<Blue notin x
doAssert <<!Blue in x
doAssert <<!Red notin x
x.enable Blue
doAssert <<Blue in x
x.enable Green
doAssert <<Green in x

type
  # take out the size param to provoke a bad error
  Size {.size: 2.} = enum
    Small
    Medium
    Large

static:
  doAssert <<Small == 1
var y: AtomicFlags32
store(y, <<{Small, Medium} + <<!Large, order = moSequentiallyConsistent)
echo "small: ", <<Small
echo "medium: ", <<Medium
echo "large: ", <<Large
doAssert <<Small in y
doAssert <<Medium in y
echo "!large: ", <<!Large
doAssert y.load && <<!Large
y.disable Small
doAssert <<!Small in y
doAssert <<Medium in y
doAssert <<!Large in y
doAssert y.load && <<!{Small, Large}
doAssert y.load && <<{Medium}
doAssert y.load !&& <<{Small, Large}
doAssert y.load !&& <<!{Medium}
y.disable Large
doAssert <<!Small in y
doAssert <<Medium in y
doAssert <<!Large in y
y.enable Large
doAssert <<!Small in y
doAssert <<Medium in y
doAssert <<Large in y
