# atomic bitset for generic enums
import std/atomics
import std/genasts
import std/macros
import std/strutils

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

proc put*[T: FlagsInts](flags: var Atomic[T]; value: T) =
  store(flags, value, order = moSequentiallyConsistent)

proc get*[T: FlagsInts](flags: var Atomic[T]): T =
  load(flags, order = moSequentiallyConsistent)

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
