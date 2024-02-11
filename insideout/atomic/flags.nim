# atomic bitset for generic enums
import std/atomics
import std/genasts
import std/macros

import insideout/futex
export checkWait, waitMask, wakeMask, FutexError

from pkg/balls import checkpoint

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
  atomicThreadFence ATOMIC_SEQ_CST

proc get*[T: FlagsInts](flags: var Atomic[T]): T =
  atomicThreadFence ATOMIC_SEQ_CST
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

when false:
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
    #checkpoint getThreadId(), "past=", past, "future=", future, "value=", value, "prior=", prior, "attempt"
    atomicThreadFence ATOMIC_SEQ_CST
    if compareExchange(flags, prior, value, order = moSequentiallyConsistent):
      atomicThreadFence ATOMIC_SEQ_CST
      #checkpoint getThreadId(), cast[uint](addr flags), "past=", past, "future=", future, "value=", value, "prior=", prior, "exchanged"
      return true
    if 0 == (prior and past) and future == (prior and future):
      #checkpoint getThreadId(), cast[uint](addr flags), "past=", past, "future=", future, "value=", value, "prior=", prior, "unneeded"
      break
    else:
      value = (prior xor past) or future

macro enable*(flags: var AtomicFlags; flag: enum): bool =
  newCall(bindSym"swap", flags,
          newCall(bindSym"<<!", flag), newCall(bindSym"<<", flag))

macro disable*(flags: var AtomicFlags; flag: enum): bool =
  newCall(bindSym"swap", flags,
          newCall(bindSym"<<", flag), newCall(bindSym"<<!", flag))
