# atomic bitset for generic enums
import std/atomics
import std/genasts
import std/macros

import insideout/spec
import insideout/futexes
export checkWait, waitMask, wakeMask, FutexError

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

macro flagType*(flag: enum): untyped =
  newCall(bindSym"flagType", newCall(bindSym"typeOf", flag))

template `<<`*[V: enum](flag: V): untyped =
  when sizeof(V) <= 1:
    1'u16 shl int(flag)
  elif sizeof(V) <= 2:
    1'u32 shl int(flag)
  else:
    {.error: "supported flag sizes are 1 and 2 bytes".}

template `<<!`*[V: enum](flag: V): untyped =
  (<< flag) shl (8 * sizeof(V))

proc sumFlags[V: enum](flags: set[V]): uint {.compileTime.} =
  for child in flags.items:
    result += 1u shl int(child)

template `<<`*[V: enum](flags: set[V]): untyped =
  when sizeof(V) <= 1:
    uint16(static sumFlags(flags))
  elif sizeof(V) <= 2:
    uint32(static sumFlags(flags))
  else:
    {.error: "supported flag sizes are 1 and 2 bytes".}

template `<<!`*[V: enum](flags: set[V]): untyped =
  (<< flags) shl (8 * sizeof(V))

proc `||`*[T: FlagsInts](a, b: T): T =
  ## (a | b) with a more natural name
  a or b

proc `||=`*[T: FlagsInts](a: var T; b: T) =
  ## (a = a | b) with a more natural name
  a = a or b

proc `&&`*[T: FlagsInts](flags: T; mask: T): bool =
  ## the mask is a subset of the flags, which is to say,
  ## mask == (flags & mask)
  mask == (flags and mask)

proc `!&&`*[T: FlagsInts](flags: T; mask: T): bool =
  ## the mask is NOT a subset of the flags, which is to say,
  ## mask != (flags & mask)
  mask != (flags and mask)

proc put*[T: FlagsInts](flags: var Atomic[T]; value: T; order = moRelease) =
  store(flags, value, order = order)

proc get*[T: FlagsInts](flags: var Atomic[T]; order = moAcquire): T =
  load(flags, order = order)

proc contains*[T: FlagsInts](flags: var Atomic[T]; mask: T): bool =
  get(flags) && mask

proc contains*(flags: var AtomicFlags16; mask: uint16): bool =
  get(flags) && mask

proc contains*(flags: var AtomicFlags32; mask: uint32): bool =
  get(flags) && mask

proc swap*[T: FlagsInts](flags: var AtomicFlags; past, future: T): bool {.discardable.} =
  assert past != 0, "missing past flags"
  assert future != 0, "missing future flags"
  assert 0 == (future and past), "flags appear in both past and future"

  when T is uint32:
    assert flags is AtomicFlags32
    var prior: uint32
  elif T is uint16:
    assert flags is AtomicFlags16
    var prior: uint16
  else:
    {.error: "unsupported AtomicFlags size".}

  var value: T = 0  # NOTE: 0 is not a valid value for flags
  while true:
    if compareExchange(flags, prior, value, order = moSequentiallyConsistent):
      return true
    if 0 == (prior and past) and future == (prior and future):
      break
    else:
      value = (prior xor past) or future

macro enable*(flags: var AtomicFlags; flag: enum): untyped =
  result =
    genAstOpt({}, flags, flag):
      if swap(flags, <<!flag, <<flag):
        debug "enable ", flag
        true
      else:
        false

macro disable*(flags: var AtomicFlags; flag: enum): bool =
  result =
    genAstOpt({}, flags, flag):
      if swap(flags, <<flag, <<!flag):
        debug "disable ", flag
        true
      else:
        false
