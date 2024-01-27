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
  WardFlag* = enum       ## flags for ward state
    Interrupt = 0  # tiny type overload for EINTR
    Paused
    Empty
    Full
    Readable
    Writable
    Bounded
  FlagT = uint32
  Ward*[T] = object
    state: AtomicFlags32
    queue: LoonyQueue[T]
    size: Atomic[int]
  BoundedWard*[T] = distinct Ward[T]
  UnboundedWard*[T] = distinct Ward[T]
  AnyWard*[T] = UnboundedWard[T] or BoundedWard[T] or Ward[T]

proc initUnboundedWard*[T](ward: var UnboundedWard[T]; queue: LoonyQueue[T]) =
  store(ward.state, <<{Writable, Readable, Empty} + <<!{Full, Paused, Bounded})
  ward.queue = queue

proc initBoundedWard*[T](ward: var BoundedWard[T]; queue: LoonyQueue[T];
                         size: Positive) =
  var flags = <<{Writable, Readable, Empty, Bounded} + <<!Paused
  if 0 == size:
    flags = flags or <<Full
  else:
    flags = flags or <<!Full
  store(ward.state, flags, order=moSequentiallyConsistent)
  store(ward.size, size, order=moSequentiallyConsistent)
  ward.queue = queue

proc newUnboundedWard*[T](): UnboundedWard[T] =
  initUnboundedWard(result, newLoonyQueue[T]())

proc newBoundedWard*[T](size: Positive = defaultInitialSize): BoundedWard[T] =
  initBoundedWard(result, newLoonyQueue[T](), size = size)

proc performWait[T](ward: var AnyWard[T]; wants: FlagT): bool {.discardable.} =
  let state = load(ward.state, order=moSequentiallyConsistent)
  result = wants != wants and state
  if result:
    checkWait waitMask(ward.state, state, wants)

proc waitForPushable*[T](ward: var AnyWard[T]): bool =
  let state = load(ward.state, order=moSequentiallyConsistent)
  if <<!Writable in state:
    false
  elif <<Paused in state:
    ward.performWait(<<!{Writable, Paused})
  elif <<Full in state:
    ward.performWait(<<!{Writable, Full})

proc waitForPoppable*[T](ward: var AnyWard[T]): bool =
  let state = load(ward.state, order=moSequentiallyConsistent)
  if <<!Readable in state:
    false
  elif <<Paused in state:
    ward.performWait(<<!{Readable, Paused})
  elif <<Empty in state:
    # NOTE: short-circuit when the ward is empty and unwritable
    if <<Writable in state:
      ward.performWait(<<!{Writable, Readable, Empty})
    else:
      false

proc performPush[T](ward: var UnboundedWard[T]; item: sink T): WardFlag =
  result = Readable
  push(ward.queue, move item)
  if disable(ward.state, Empty):
    discard wakeMask(ward.state, <<!Empty, 1)

proc markFull[T](ward: var BoundedWard[T]): WardFlag =
  ## mark the ward as full and wake a waiter
  if enable(ward.state, Full):
    discard wakeMask(ward.state, <<Full, 1)

proc performPush[T](ward: var BoundedWard[T]; item: sink T): WardFlag =
  template pushImpl(): untyped =
    # we won the right to safely push
    push(ward.queue, move item)
    result = Readable
    # optimistically declare the ward un-empty; a lost
    # race here simply wakes a waiter harmlessly
    if disable(ward.state, Empty):
      discard wakeMask(ward.state, <<!Empty, 1)
  while true:
    var prior = 1
    # try to claim the last slot, and assign `prior`
    if compareExchange(ward.size, prior, 0, order = moSequentiallyConsistent):
      pushImpl()
      # as expected, we're full
      ward.markFull()
      break
    elif prior == 0:
      # surprise, we're full
      result = Full
      break
    elif compareExchange(ward.size, prior, prior - 1,
                         order = moSequentiallyConsistent):
      # not full yet
      pushImpl()
      break
    else:
      # race case: failed to win our slot
      result = Interrupt
      when defined(danger):
        # spin to avoid a context switch
        discard
      else:
        # bomb out to try again later
        break

proc tryPush*[T](ward: var AnyWard[T]; item: var T): WardFlag =
  let state = load(ward.state, order=moSequentiallyConsistent)
  if <<!Writable in state:
    Writable
  elif <<Full in state:
    Full
  elif <<Paused in state:
    Paused
  else:
    ward.performPush(move item)

proc push*[T](ward: var AnyWard[T]; item: var T): WardFlag =
  while true:
    result = ward.tryPush(item)
    case result
    of Readable, Writable:
      break
    of Full:
      if not ward.performWait(<<!{Writable, Full}):
        result = Writable
        break
    of Paused:
      if not ward.performWait(<<!{Writable, Paused}):
        result = Writable
        break
    else:
      discard

proc markEmpty[T](ward: var AnyWard[T]): WardFlag =
  ## mark the ward as empty; if it's also unwritable,
  ## then mark it as unreadable and wake everyone up.
  let state = load(ward.state, order=moSequentiallyConsistent)
  # NOTE: short-circuit when the ward is empty and unwritable
  if <<!Writable in state:
    result = Readable
    var woke = false
    woke = woke or enable(ward.state, Empty)
    woke = woke or disable(ward.state, Readable)
    if woke:
      wakeMask(ward.state, <<Empty + <<!{Readable, Writable})
  else:
    result = Empty
    if enable(ward.state, Empty):
      discard wakeMask(ward.state, <<Empty, 1)

proc performPop[T](ward: var UnboundedWard[T]; item: var T): WardFlag =
  item = pop(ward.queue)
  if item.isNil:
    result = ward.markEmpty()
  else:
    result = Writable

proc performPop[T](ward: var BoundedWard[T]; item: var T): WardFlag =
  item = pop(ward.queue)
  if item.isNil:
    result = ward.markEmpty()
  else:
    result = Writable
    # XXX
    if <<Bounded in load(ward.state, order=moSequentiallyConsistent):
      let count = fetchAdd(ward.size, 1, order = moSequentiallyConsistent)
      if 0 == count:
        if disable(ward.state, Full):
          discard wakeMask(ward.state, <<!Full, 1)

proc tryPop*[T](ward: var AnyWard[T]; item: var T): WardFlag =
  let state = load(ward.state, order=moSequentiallyConsistent)
  if <<!Readable in state:
    Readable
  elif <<Empty in state:
    Empty
  elif <<Paused in state:
    Paused
  else:
    ward.performPop(item)

proc pop*[T](ward: var AnyWard[T]; item: var T): WardFlag =
  while true:
    result = ward.tryPop(item)
    case result
    of Readable, Writable:
      break
    of Empty:
      if not ward.performWait(<<!{Readable, Empty, Writable}):
        result = Readable
        break
    of Paused:
      if not ward.performWait(<<!{Readable, Paused}):
        result = Readable
        break
    else:
      discard

proc closeRead*[T](ward: var AnyWard[T]) =
  if disable(ward.state, Readable):
    wakeMask(ward.state, <<!Readable)

proc closeWrite*[T](ward: var AnyWard[T]) =
  if disable(ward.state, Writable):
    wakeMask(ward.state, <<!Writable)

proc pause*[T](ward: var AnyWard[T]) =
  if enable(ward.state, Paused):
    wakeMask(ward.state, <<Paused)

proc resume*[T](ward: var AnyWard[T]) =
  if disable(ward.state, Paused):
    wakeMask(ward.state, <<!Paused)

template withPaused[T](ward: var AnyWard[T]; body: typed): untyped =
  pause ward
  try:
    body
  finally:
    resume ward

proc clear*[T](ward: var AnyWard[T]) =
  withPaused ward:
    while not pop(ward.queue).isNil:
      discard

proc waitForEmpty*[T](ward: var AnyWard[T]) =
  while true:
    let state = load(ward.state, order=moSequentiallyConsistent)
    if <<Empty in state:
      break
    discard waitMask(ward.state, state, <<Empty)

proc waitForFull*[T](ward: var AnyWard[T]) =
  while true:
    let state = load(ward.state, order=moSequentiallyConsistent)
    if <<Full in state:
      break
    checkWait waitMask(ward.state, state, <<Full)
