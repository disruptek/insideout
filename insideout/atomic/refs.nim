import std/atomics
import std/strutils

import insideout/valgrind

type
  Reference[T] = object
    value: T
    rc: Atomic[int]

  AtomicRef*[T] = object
    reference: ptr Reference[T]

proc `=copy`*[T](dest: var Reference[T]; src: Reference[T]) {.error.}

proc isNil*[T](arc: AtomicRef[T]): bool =
  arc.reference.isNil

from pkg/balls import checkpoint

proc `=destroy`*[T](arc: var AtomicRef[T]) =
  mixin `=destroy`
  if not arc.reference.isNil:
    let n = fetchSub(arc.reference[].rc, 1, order = moSequentiallyConsistent)
    if 0 == n:
      happensAfter(addr arc.reference[].rc)
      happensBeforeForgetAll(addr arc.reference[].rc)
      checkpoint "!ref:", $T, cast[int](arc.reference).toHex, " (destroy)"
      `=destroy`(arc.reference[])
      deallocShared arc.reference
      arc.reference = nil
    else:
      checkpoint "-ref:", $T, cast[int](arc.reference).toHex, load(arc.reference[].rc)
      happensBefore(addr arc.reference[].rc)
      arc.reference = nil

proc `=copy`*[T](target: var AtomicRef[T]; source: AtomicRef[T]) =
  mixin `=destroy`
  if not target.isNil:
    checkpoint "<ref:", $T, cast[int](target.reference).toHex, load(target.reference[].rc)
    `=destroy`(target)
  if not source.isNil:
    discard fetchAdd(source.reference.rc, 1, order = moSequentiallyConsistent)
    checkpoint "+ref:", $T, cast[int](source.reference).toHex, load(source.reference[].rc)
  target.reference = source.reference

proc forget*[T](arc: AtomicRef[T]) =
  if not arc.isNil:
    discard fetchSub(arc.reference.rc, 1, order = moSequentiallyConsistent)
    checkpoint "-ref:", $T, cast[int](arc.reference).toHex, load(arc.reference.rc)

proc remember*[T](arc: AtomicRef[T]) =
  if not arc.isNil:
    discard fetchAdd(arc.reference.rc, 1, order = moSequentiallyConsistent)
    checkpoint "+ref:", $T, cast[int](arc.reference).toHex, load(arc.reference.rc)

proc owners*[T](arc: AtomicRef[T]): int =
  ## returns the number of owners; this value is positive for
  ## initialized references and zero for all others
  if not arc.isNil:
    result = load(arc.reference.rc, order = moSequentiallyConsistent) + 1
    if result <= 0:
      raise Defect.newException "atomic ref underrun: " & $result

proc new*[T](arc: var AtomicRef[T]) =
  if not arc.isNil:
    checkpoint ">ref:", $T, cast[int](arc.reference).toHex, load(arc.reference[].rc)
    `=destroy`(arc)
  arc.reference = cast[ptr Reference[T]](allocShared0(sizeof Reference[T]))
  if arc.reference.isNil:
    raise OSError.newException "unable to alloc memory for AtomicRef"
  checkpoint "+ref:", $T, cast[int](arc.reference).toHex, load(arc.reference[].rc)

proc `[]`*[T](arc: AtomicRef[T]): var T =
  when defined(danger):
    result = arc.reference[].value
  else:
    if arc.isNil:
      raise Defect.newException "dereference of nil atomic ref " & $T
    else:
      result = arc.reference[].value

proc address*(arc: AtomicRef): pointer =
  arc.reference

converter dereference*[T](arc: AtomicRef[T]): var T = arc[]
