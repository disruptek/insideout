# atomic bitset for generic enums
import std/macros
import std/atomics

import insideout/futex

# this is a bit loony but we want to support nimskull, so...

type
  AtomicFlags*[T] = Atomic[T]

macro getFlags*[T](flags: var AtomicFlags[T]): T =
  newCall(bindSym"load", flags, bindSym"moSequentiallyConsistent")

template flagType*(flag: typedesc): untyped =
  when sizeof(flag) <= 2:
    uint16
  elif sizeof(flag) <= 4:
    uint32
  elif sizeof(flag) <= 8:
    uint64
  else:
    {.error: "bad idea".}

template flagType*[V](flag: V): untyped =
  flagType(typeOf flag)

proc toFlag*[V](flag: V): auto =
  flagType(flag)(1) shl ord(flag)

proc toFlags*[T; V](value: T): set[V] {.discardable.} =
  when nimvm:
    for flag in V.items:
      if 0 != (value and flag.toFlag):
        result.incl flag
  else:
    result = cast[set[V]](value)

proc toFlags*[T; V](flags: set[V]): T =
  for flag in flags.items:
    result = result or flag.toFlag

proc toFlags*[T; V](flags: var AtomicFlags[T]): set[V] {.discardable.} =
  toFlags[T, V](getFlags(flags))

proc contains*[T; V](flags: var AtomicFlags[T]; one: V): bool =
  0 != (getFlags(flags) and one.toFlag)

proc contains*[T; V](flags: var AtomicFlags[T]; many: set[V]): bool =
  0 != (getFlags(flags) and toFlags[T, V](many))

macro `|=`*[T; V](flags: var AtomicFlags[T]; one: V): set[V] =
  let fType = newCall(bindSym"flagType", one)
  let toFlags = nnkBracketExpr.newTree(bindSym"toFlags", fType,
                                       getTypeInst(one))
  newCall(toFlags, newCall(bindSym"fetchOr", flags,
          newCall(bindSym"toFlag", one), bindSym"moSequentiallyConsistent"))

macro `^=`*[T; V](flags: var AtomicFlags[T]; one: V): set[V] =
  let fType = newCall(bindSym"flagType", one)
  let toFlags = nnkBracketExpr.newTree(bindSym"toFlags", fType,
                                       getTypeInst(one))
  newCall(toFlags, newCall(bindSym"fetchXor", flags,
          newCall(bindSym"toFlag", one), bindSym"moSequentiallyConsistent"))

macro `|=`*[T; V](flags: var AtomicFlags[T]; many: set[V]): set[V] =
  let t = getTypeInst(many)[^1]
  let fType = newCall(bindSym"flagType", t)
  let toFlags = nnkBracketExpr.newTree(bindSym"toFlags", fType, t)
  newCall(toFlags, newCall(bindSym"fetchOr", flags,
          newCall(toFlags, many), bindSym"moSequentiallyConsistent"))

macro `^=`*[T; V](flags: var AtomicFlags[T]; many: set[V]): set[V] =
  let t = getTypeInst(many)[^1]
  let fType = newCall(bindSym"flagType", t)
  let toFlags = nnkBracketExpr.newTree(bindSym"toFlags", fType, t)
  newCall(toFlags, newCall(bindSym"fetchXor", flags,
          newCall(toFlags, many), bindSym"moSequentiallyConsistent"))

proc waitMask*[T; V](flags: var AtomicFlags[T]; mask: set[V]): cint
  {.discardable, inline.} =
  waitMask(flags, toFlags[T, V](mask))

proc waitMask*[T; V](flags: var AtomicFlags[T]; compare: T;
                     mask: set[V]): cint {.discardable, inline.} =
  waitMask(flags, cast[AtomicFlags[T]](compare), toFlags[T, V](mask))

proc wakeMask*[T; V](flags: var AtomicFlags[T]; mask: set[V];
                  count = high(cint)): cint {.discardable, inline.} =
  wakeMask(flags, toFlags[T, V](mask), count = count)
