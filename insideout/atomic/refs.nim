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

proc debug[T](arc: AtomicRef[T]; s: string; m: string) =
  when not defined(danger):
    when not defined(release):
      if not arc.reference.isNil:
        checkpoint s & ":", T, cast[int](arc.reference).toHex.toLowerAscii, m

proc `=destroy`*[T](arc: var AtomicRef[T]) =
  mixin `=destroy`
  if not arc.reference.isNil:
    let n = fetchSub(arc.reference[].rc, 1, order = moSequentiallyConsistent)
    if 0 == n:
      happensAfter(addr arc.reference[].rc)
      happensBeforeForgetAll(addr arc.reference[].rc)
      arc.debug "!ref", "(destroy)"
      `=destroy`(arc.reference[])
      deallocShared arc.reference
      arc.reference = nil
    else:
      arc.debug "-ref", "(destroy)"
      happensBefore(addr arc.reference[].rc)
      arc.reference = nil

proc `=copy`*[T](target: var AtomicRef[T]; source: AtomicRef[T]) =
  mixin `=destroy`
  if not target.isNil:
    target.debug "<ref", "(copy)"
    `=destroy`(target)
  if not source.isNil:
    discard fetchAdd(source.reference.rc, 1, order = moSequentiallyConsistent)
    source.debug "+ref", "(copy)"
    target.reference = source.reference

proc forget*[T](arc: AtomicRef[T]) =
  if not arc.isNil:
    discard fetchSub(arc.reference.rc, 1, order = moSequentiallyConsistent)
    arc.debug "-ref", "(forget)"

proc remember*[T](arc: AtomicRef[T]) =
  if not arc.isNil:
    discard fetchAdd(arc.reference.rc, 1, order = moSequentiallyConsistent)
    arc.debug "+ref", "(remember)"

proc owners*[T](arc: AtomicRef[T]): int =
  ## returns the number of owners; this value is positive for
  ## initialized references and zero for all others
  if not arc.isNil:
    result = load(arc.reference.rc, order = moSequentiallyConsistent) + 1
    if result <= 0:
      raise Defect.newException "atomic ref underrun: " & $result

proc new*[T](arc: var AtomicRef[T]) =
  if not arc.isNil:
    arc.debug ">ref", "(new)"
    `=destroy`(arc)
  arc.reference = cast[ptr Reference[T]](allocShared0(sizeof Reference[T]))
  if arc.reference.isNil:
    raise OSError.newException "unable to alloc memory for AtomicRef"
  arc.debug "+ref", "(new)"

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

when false:
  converter dereference*[T](arc: AtomicRef[T]): var T = arc[]
