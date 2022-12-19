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
    if 0 == fetchSub(arc.reference.rc, 1, moAcquire):
      `=destroy`(arc.reference[])
      deallocShared arc.reference
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
    result = load(arc.reference.rc, moAcquire) + 1
    if result <= 0:
      raise Defect.newException "atomic ref underrun: " & $result

proc new*[T](arc: var AtomicRef[T]) {.inline.} =
  if arc.isNil:
    arc.reference = cast[ptr Reference[T]](allocShared0(sizeof Reference[T]))
    # NOTE: we cannot destroy/reset the arc.reference.value here because
    #       it might contain a thread or mutex or condvar, etc.
    #store(arc.reference.rc, 0, moRelease)
  else:
    raise ValueError.newException "attempt to reinitialize atomic ref"

converter dereference*[T](arc: AtomicRef[T]): var T {.inline.} =
  if arc.isNil:
    raise Defect.newException "dereference of nil atomic ref " & $T
  else:
    result = arc.reference[].value

proc `[]`*[T](arc: AtomicRef[T]): var T {.inline.} =
  if arc.isNil:
    raise Defect.newException "dereference of nil atomic ref " & $T
  else:
    result = arc.reference[].value

proc address*(arc: AtomicRef): pointer {.inline.} =
  arc.reference
