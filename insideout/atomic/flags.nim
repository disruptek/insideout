# atomic bitset for generic enums
import std/macros
import std/atomics

import insideout/futex

type
  AtomicFlags*[T] = Atomic[uint32]

macro getFlags*(flags: var AtomicFlags): uint32 =
  newCall(bindSym"load", flags, bindSym"moSequentiallyConsistent")

template flagType*[T](flag: T): untyped =
  when sizeof(T) <= 4:
    uint32
  else:
    {.error: "flag type must be <= 4 bytes".}

template toFlag*[T](flag: T): untyped =
  uint32(1) shl ord(flag)

proc toFlags*[T](value: uint32): set[T] {.discardable.} =
  when nimvm:
    for flag in T.items:
      if 0 != (value and flag.toFlag):
        result.incl flag
  else:
    result = cast[set[T]](value)

proc toFlags*[T](flags: set[T]): uint32 =
  for flag in flags.items:
    result = result or flag.toFlag

proc toFlags*[T](flags: var AtomicFlags[T]): set[T] {.discardable.} =
  toFlags[T](getFlags(flags))

proc contains*[T](flags: var AtomicFlags[T]; one: T): bool =
  0 != (getFlags(flags) and one.toFlag)

proc contains*[T](flags: var AtomicFlags[T]; many: set[T]): bool =
  0 != (getFlags(flags) and toFlags[T](many))

macro `|=`*[T](flags: var AtomicFlags[T]; one: T): set[T] =
  let toFlags = nnkBracketExpr.newTree(bindSym"toFlags", getTypeInst(one))
  newCall(toFlags, newCall(bindSym"fetchOr", flags,
          newCall(bindSym"toFlag", one), bindSym"moSequentiallyConsistent"))

macro `^=`*[T](flags: var AtomicFlags[T]; one: T): set[T] =
  let toFlags = nnkBracketExpr.newTree(bindSym"toFlags", getTypeInst(one))
  newCall(toFlags, newCall(bindSym"fetchXor", flags,
          newCall(bindSym"toFlag", one), bindSym"moSequentiallyConsistent"))

macro `|=`*[T](flags: var AtomicFlags[T]; many: set[T]): set[T] =
  let t = getTypeInst(many)[^1]
  let toFlags = nnkBracketExpr.newTree(bindSym"toFlags", t)
  newCall(toFlags, newCall(bindSym"fetchOr", flags,
          newCall(bindSym"toFlags", many), bindSym"moSequentiallyConsistent"))

macro `^=`*[T](flags: var AtomicFlags[T]; many: set[T]): set[T] =
  let t = getTypeInst(many)[^1]
  let toFlags = nnkBracketExpr.newTree(bindSym"toFlags", t)
  newCall(toFlags, newCall(bindSym"fetchXor", flags,
          newCall(toFlags, many), bindSym"moSequentiallyConsistent"))

proc waitMask*[T](flags: var AtomicFlags[T]; mask: set[T]): cint {.discardable, inline.} =
  waitMask(flags, toFlags[T](mask))

proc waitMask*[T](flags: var AtomicFlags[T]; compare: uint32; mask: set[T]): cint {.discardable, inline.} =
  waitMask(flags, cast[AtomicFlags[T]](compare), toFlags[T](mask))

proc wakeMask*[T](flags: var AtomicFlags[T]; mask: set[T];
                  count = high(cint)): cint {.discardable, inline.} =
  wakeMask(flags, toFlags[T](mask), count = count)
