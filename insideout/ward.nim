# TODO: wake on bitmask
#       order flags by priority
#       don't sweat races on flags
import std/atomics
import std/os
import std/posix
import std/sets

import pkg/loony

import insideout/futex
import insideout/atomic/flags

type
  WardFlag* = enum       ## \
    ## we do this silly thing so we can construct a futex
    ##
    Interrupt = 0  # tiny type overload for EINTR
    Paused
    NotPaused
    Empty
    NotEmpty
    Full
    NotFull
    Readable
    NotReadable
    Writable
    NotWritable
  WardFlags = set[WardFlag]
  FlagT = uint32
  UnboundedWard*[T] = object
    state: AtomicFlags[FlagT]
    queue: LoonyQueue[T]
  BoundedWard*[T] = object
    state: AtomicFlags[FlagT]
    queue: LoonyQueue[T]
    size: Atomic[int]
  Ward*[T] = UnboundedWard[T] or BoundedWard[T]

proc flags*[T](ward: var Ward[T]): set[WardFlag] =
  toFlags[FlagT, WardFlag](getFlags ward.state)

proc initWard*[T](ward: var UnboundedWard[T]; queue: LoonyQueue[T]) =
  ward.state |= {Writable, Readable, Empty, NotFull, NotPaused}
  ward.queue = queue

proc initWard*[T](ward: var BoundedWard[T]; queue: LoonyQueue[T];
                  size: Natural) =
  var flags: WardFlags = {Writable, Readable, Empty, NotPaused}
  if 0 == size:
    flags.incl Full
  else:
    flags.incl NotFull
  store(ward.size, size, order=moSequentiallyConsistent)
  store(ward.state, toFlags[FlagT, WardFlag](flags),
        order=moSequentiallyConsistent)
  ward.queue = queue

proc newUnboundedQueue*[T](): UnboundedWard[T] =
  initWard(result, newLoonyQueue[T]())

proc newBoundedQueue*[T](size: Natural = defaultInitialSize): BoundedWard[T] =
  initWard(result, newLoonyQueue[T](), size = size)

proc performWait(ward: var Ward; wants: set[WardFlag]): bool {.discardable.} =
  let state = getFlags ward.state
  let has = toFlags[FlagT, WardFlag](state)
  result = wants * has == {}
  if result:
    checkWait waitMask(ward.state, state, wants)

proc waitForPushable*[T](ward: var Ward[T]): bool =
  let flags = toFlags[FlagT, WardFlag](ward.state)
  result = Writable in flags
  if result:
    if Paused in flags:
      ward.performWait({NotWritable, NotPaused})
    elif Full in flags:
      ward.performWait({NotWritable, NotFull})

proc waitForPoppable*[T](ward: var Ward[T]): bool =
  let flags = toFlags[FlagT, WardFlag](ward.state)
  result = Readable in flags
  if result:
    if Paused in flags:
      ward.performWait({NotReadable, NotPaused})
    elif Empty in flags:
      result = Writable in flags
      if result:
        ward.performWait({NotWritable, NotReadable, NotEmpty})

proc toggle*[T](ward: var Ward[T]; past, future: WardFlag): bool {.discardable.} =
  ward.state.toggle(past, future)

proc unmarkEmpty*[T](ward: var Ward[T]) =
  if ward.toggle(Empty, NotEmpty):
    wakeMask(ward.state, {NotEmpty}, 1)

proc performPush[T](ward: var Ward[T]; item: sink T): WardFlag =
  result = Readable
  when ward is BoundedWard:
    # if we just hit full,
    let count = fetchSub(ward.size, 1, order = moSequentiallyConsistent)
    if 1 == count:
      var full = ward.toggle(NotFull, Full)
      try:
        # we can safely push
        push(ward.queue, move item)
      finally:
        if full:
          let woke = wakeMask(ward.state, {Full}, 1)
        else:
          raise Defect.newException "race in push"
    elif 1 > count:
      # race case
      discard fetchAdd(ward.size, 1, order = moSequentiallyConsistent)
      result = Interrupt
      raise Defect.newException "unexpected race"
    else:
      # we can safely push
      push(ward.queue, move item)
  else:
    # unbounded queue; we can safely push
    push(ward.queue, move item)
  ward.unmarkEmpty()

proc tryPush*[T](ward: var Ward[T]; item: var T): WardFlag =
  let flags = toFlags[FlagT, WardFlag](ward.state)
  if Writable notin flags:
    result = Writable
  elif Full in flags:
    result = Full
  elif Paused in flags:
    result = Paused
  else:
    result = ward.performPush(move item)

proc push*[T](ward: var Ward[T]; item: var T): WardFlag =
  while true:
    result = ward.tryPush(item)
    case result
    of Readable, Writable:
      break
    of Full:
      discard ward.performWait({NotWritable, NotFull})
    of Paused:
      discard ward.performWait({NotWritable, NotPaused})
    else:
      discard

proc performPop[T](ward: var Ward[T]; item: var T): WardFlag =
  item = pop(ward.queue)
  if item.isNil:
    result = Empty
    if ward.toggle(NotEmpty, Empty):
      wakeMask(ward.state, {Empty}, 1)
  else:
    result = Writable
    when ward is BoundedWard:
      let count = fetchAdd(ward.size, 1, order = moSequentiallyConsistent)
      if 0 == count:
        if ward.toggle(Full, NotFull):
          wakeMask(ward.state, {NotFull}, 1)

proc tryPop*[T](ward: var Ward[T]; item: var T): WardFlag =
  let flags = toFlags[FlagT, WardFlag](ward.state)
  if Readable notin flags:
    result = Readable
  elif Empty in flags:
    result = Empty
  elif Paused in flags:
    result = Paused
  else:
    result = ward.performPop(item)

proc pop*[T](ward: var Ward[T]; item: var T): WardFlag =
  while true:
    result = ward.tryPop(item)
    case result
    of Readable, Writable:
      break
    of Empty:
      discard ward.performWait({NotReadable, NotEmpty})
    of Paused:
      discard ward.performWait({NotReadable, NotPaused})
    else:
      discard

proc closeRead*[T](ward: var Ward[T]) =
  if ward.toggle(Readable, NotReadable):
    wakeMask(ward.state, {NotReadable})

proc closeWrite*[T](ward: var Ward[T]) =
  if ward.toggle(Writable, NotWritable):
    wakeMask(ward.state, {NotWritable})

proc pause*[T](ward: var Ward[T]) =
  if ward.toggle(NotPaused, Paused):
    wakeMask(ward.state, {Paused})

proc resume*[T](ward: var Ward[T]) =
  if ward.toggle(Paused, NotPaused):
    wakeMask(ward.state, {NotPaused})

template withPaused[T](ward: var Ward[T]; body: typed): untyped =
  pause ward
  try:
    body
  finally:
    resume ward

proc clear*[T](ward: var Ward[T]) =
  withPaused ward:
    while not pop(ward.queue).isNil:
      discard

proc waitForEmpty*[T](ward: var Ward[T]) =
  while true:
    let state: FlagT = getFlags ward.state
    let flags = toFlags[FlagT, WardFlag](state)
    if Empty in flags:
      break
    discard waitMask(ward.state, state, {Empty})

proc waitForFull*[T](ward: var Ward[T]) =
  while true:
    let state: FlagT = getFlags ward.state
    var flags = toFlags[FlagT, WardFlag](state)
    if Full in flags:
      break
    checkWait waitMask(ward.state, state, {Full})
