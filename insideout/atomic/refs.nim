import std/atomics

type
  Reference[T] = object
    value: T
    rc: Atomic[int]

  AtomicRef*[T] = object
    reference: ptr Reference[T]

proc `=copy`*[T](dest: var Reference[T]; src: Reference[T]) {.error.}

proc isNil*[T](arc: AtomicRef[T]): bool {.inline.} =
  arc.reference.isNil

proc `=destroy`*[T](arc: var AtomicRef[T]) {.inline.} =
  mixin `=destroy`
  if not arc.isNil:
    if 0 == fetchSub(arc.reference[].rc, 1):
      `=destroy`(arc.reference[])
      deallocShared arc.reference
      arc.reference = nil
    else:
      arc.reference = nil

proc `=copy`*[T](dest: var AtomicRef[T]; src: AtomicRef[T]) {.inline.} =
  mixin `=destroy`
  if not src.isNil:
    discard fetchAdd(src.reference.rc, 1)
  if not dest.isNil:
    `=destroy`(dest)
  dest.reference = src.reference

proc owners*[T](arc: AtomicRef[T]): int {.inline.} =
  ## returns the number of owners; this value is positive for
  ## initialized references and zero for all others
  if not arc.isNil:
    result = load(arc.reference.rc) + 1
    if result <= 0:
      raise Defect.newException "atomic ref underrun: " & $result

proc new*[T](arc: var AtomicRef[T]) {.inline.} =
  if not arc.isNil:
    `=destroy`(arc)
  arc.reference = cast[ptr Reference[T]](allocShared0(sizeof Reference[T]))
  if arc.reference.isNil:
    raise Defect.newException "unable to alloc memory for AtomicRef"

proc `[]`*[T](arc: AtomicRef[T]): var T {.inline.} =
  if arc.isNil:
    raise Defect.newException "dereference of nil atomic ref " & $T
  else:
    result = arc.reference[].value

proc address*(arc: AtomicRef): pointer {.inline.} =
  arc.reference

converter dereference*[T](arc: AtomicRef[T]): var T {.inline.} = arc[]
