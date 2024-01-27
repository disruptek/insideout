# atomic bitset for generic enums
import std/atomics
import std/genasts
import std/macros

import insideout/futex
export checkWait

# this is a bit loony but we want to support nimskull, so...

type
  AtomicFlags16* = Atomic[uint16]
  AtomicFlags32* = Atomic[uint32]
  AtomicFlags = AtomicFlags16 or AtomicFlags32

template flagType*(flag: typedesc): untyped =
  when sizeof(flag) <= 1:
    uint16
  elif sizeof(flag) <= 2:
    uint32
  else:
    {.error: "supported flag sizes are 1 and 2 bytes".}

template flagType*[V: enum](flag: V): untyped =
  flagType(typeOf flag)

macro `<<`*[V: enum](flag: V): untyped =
  genAstOpt {}, V, flag:
    flagType(V)(1) shl ord(flag)

macro `<<!`*[V: enum](flag: V): untyped =
  genAstOpt {}, V, flag:
    (<< flag) shl (8 * sizeof(V))

macro `<<`*[V: enum](flags: set[V]): untyped =
  var sum: BiggestInt = 0
  for child in flags.children:
    sum = sum + (1 shl child.intVal)
  genAstOpt {}, V, sum=newLit sum:
    flagType(V)(sum)

macro `<<!`*[V: enum](flags: set[V]): untyped =
  genAstOpt {}, V, flags:
    (<< flags) shl (8 * sizeof(V))

proc contains*(flags: var AtomicFlags; mask: uint16 or uint32): bool =
  0 != (load(flags, order = moSequentiallyConsistent) and mask)

proc toSet*[V](value: var AtomicFlags): set[V] {.error.} =
  let value = load(value, order = moSequentiallyConsistent)
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

proc swap(flags: var AtomicFlags16; past, future: uint16): bool {.discardable.} =
  var prior: uint16
  while 0 == (prior and future):
    if compareExchange(flags, prior, (prior or future) xor past,
                       order = moSequentiallyConsistent):
      return true
  return false

proc swap(flags: var AtomicFlags32; past, future: uint32): bool {.discardable.} =
  var prior: uint32
  while 0 == (prior and future):
    if compareExchange(flags, prior, (prior or future) xor past,
                       order = moSequentiallyConsistent):
      return true
  return false

macro enable*[V: enum](flags: var AtomicFlags; flag: V): bool =
  newCall(bindSym"swap", flags,
          newCall(bindSym"<<!", flag), newCall(bindSym"<<", flag))

macro disable*[V: enum](flags: var AtomicFlags; flag: V): bool =
  newCall(bindSym"swap", flags,
          newCall(bindSym"<<", flag), newCall(bindSym"<<!", flag))

proc toggle*[V: enum](flags: var AtomicFlags; flag: V): auto
  {.discardable.} =
  fetchXor(flags, (<<! flag) or (<< flag),
           order = moSequentiallyConsistent)
