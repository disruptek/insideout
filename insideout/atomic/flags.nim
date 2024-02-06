# atomic bitset for generic enums
import std/atomics
import std/bitops
import std/genasts
import std/macros

import insideout/futex
export checkWait, waitMask, wakeMask

type
  AtomicFlags16* = Atomic[uint16]
  AtomicFlags32* = Atomic[uint32]
  AtomicFlags = AtomicFlags16 or AtomicFlags32
  FlagsInts = uint16 or uint32

template flagType*(flag: typedesc[enum]): untyped =
  when sizeof(flag) <= 1:
    uint16
  elif sizeof(flag) <= 2:
    uint32
  else:
    {.error: "supported flag sizes are 1 and 2 bytes".}

type
  e {.pure.} = enum x, y

doAssert flagType(e) is uint16

macro flagType*(flag: enum): untyped =
  newCall(bindSym"flagType", newCall(bindSym"typeOf", flag))

macro `<<`*[V: enum](flag: V): untyped =
  let shift = flag.intVal
  genAstOpt({}, v=getType(flag), shift=newLit(shift)):
    when sizeof(v) <= 1:
      1'u16 shl shift
    elif sizeof(v) <= 2:
      1'u32 shl shift
    else:
      {.error: "supported flag sizes are 1 and 2 bytes".}

macro `<<!`*[V: enum](flag: V): untyped =
  genAstOpt({}, v=getType(flag), flag):
    (<< flag) shl (8 * sizeof(v))

macro `<<`*[V: enum](flags: set[V]): untyped =
  var sum: int = 0
  for child in flags.children:
    sum = sum + (1 shl child.intVal)
  if sum == 0:
    return newLit(0)
  result =
    genAstOpt({}, v=getType(flags)[^1][^1], sum=newLit(sum)):
      when sizeof(v) <= 1:
        uint16(sum)
      elif sizeof(v) <= 2:
        uint32(sum)
      else:
        {.error: "supported flag sizes are 1 and 2 bytes".}

macro `<<!`*[V: enum](flags: set[V]): untyped =
  genAstOpt({}, v=getType(flags)[^1][^1], flags):
    (<< flags) shl (8 * sizeof(v))

proc `||`*[T: FlagsInts](a, b: T): T =
  ## expose bitor with a more natural name
  bitor(a, b)

proc `||=`*[T: FlagsInts](a: var T; b: T) =
  ## bitor assignment with a more natural name
  a = a || b

proc `&&`*[T: FlagsInts](flags: T; mask: T): bool =
  ## the mask is a subset of the flags
  mask == bitand(flags, mask)

proc `!&&`*[T: FlagsInts](flags: T; mask: T): bool =
  ## the mask is not a subset of the flags
  not (flags && mask)

proc get*[T: FlagsInts](flags: var Atomic[T]): T =
  atomicThreadFence(ATOMIC_ACQUIRE)
  load(flags, order = moSequentiallyConsistent)

proc contains*[T: FlagsInts](flags: var Atomic[T]; mask: T): bool =
  get(flags) && mask

proc contains*[T: FlagsInts](flags: Atomic[T]; mask: T): bool {.error: "immutable flags".}

proc contains*(flags: var AtomicFlags16; mask: uint16): bool =
  get(flags) && mask

proc contains*(flags: AtomicFlags16; mask: uint16): bool {.error: "immutable flags".}

proc contains*(flags: var AtomicFlags32; mask: uint32): bool =
  get(flags) && mask

proc contains*(flags: AtomicFlags32; mask: uint32): bool {.error: "immutable flags".}

proc toSet*[V](value: var AtomicFlags): set[V] {.error.} =
  let value = get value
  when nimvm:
    for flag in V.items:
      if 0 != (value and (<< flag)):
        result.incl flag
  else:
    result = cast[set[V]](value)

macro waitMask*[V](flags: var AtomicFlags; mask: set[V]): cint =
  newCall(bindSym"waitMask", flags, newCall(bindSym"<<", mask))

macro waitMaskNot*[V](flags: var AtomicFlags; mask: set[V]): cint =
  newCall(bindSym"waitMask", flags, newCall(bindSym"<<!", mask))

macro wakeMask*[V](flags: var AtomicFlags; mask: set[V];
                   count = high(cint)): cint {.discardable.} =
  newCall(bindSym"wakeMask", flags, newCall(bindSym"<<", mask), count)

macro wakeMaskNot*[V](flags: var AtomicFlags; mask: set[V];
                   count = high(cint)): cint {.discardable.} =
  newCall(bindSym"wakeMask", flags, newCall(bindSym"<<!", mask), count)

proc swap*[T: FlagsInts](flags: var AtomicFlags; past, future: T): bool {.discardable.} =
  when T is uint32:
    assert flags is AtomicFlags32
    var prior: uint32
  elif T is uint16:
    assert flags is AtomicFlags16
    var prior: uint16
  else:
    {.error: "wut".}
  let mask = bitnot(past)   # future flags not in past flags
  when defined(danger):
    # expect a normal transition
    template test(): untyped = prior !&& future
  else:
    # check that the flags aren't corrupted somehow
    template test(): untyped = (prior !&& mask) or (prior && past)
    if future != bitand(mask, future):
      raise Defect.newException "future flags contain past flags"
  while test():
    var value = bitor(bitand(mask, prior), future)
    atomicThreadFence(ATOMIC_ACQUIRE)
    if compareExchange(flags, prior, value, order = moSequentiallyConsistent):
      atomicThreadFence(ATOMIC_RELEASE)
      return true
    else:
      atomicThreadFence(ATOMIC_RELEASE)
  return false

macro enable*(flags: var AtomicFlags; flag: enum): bool =
  newCall(bindSym"swap", flags,
          newCall(bindSym"<<!", flag), newCall(bindSym"<<", flag))

macro disable*(flags: var AtomicFlags; flag: enum): bool =
  newCall(bindSym"swap", flags,
          newCall(bindSym"<<", flag), newCall(bindSym"<<!", flag))
