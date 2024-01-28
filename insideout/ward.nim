import std/atomics
import std/os
import std/posix
import std/sets

import pkg/loony

import insideout/futex
import insideout/atomic/flags

type
  WardFlag* {.size: 2.} = enum       ## flags for ward state
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

proc pause*[T](ward: var Ward[T])

proc initWard*[T](ward: var Ward[T]; queue: LoonyQueue[T]) =
  const flags =
    <<{Writable, Readable, Empty} + <<!{Full, Paused, Bounded}
  # support reinitialization
  if not ward.queue.isNil:
    pause ward
    while ward.queue.pop.isNil:
      discard
    reset ward.queue
  store(ward.size, 0, order=moSequentiallyConsistent)
  store(ward.state, flags, order=moSequentiallyConsistent)
  ward.queue = queue

proc initWard*[T](ward: var Ward[T]; queue: LoonyQueue[T];
                         size: Positive) =
  const flags =
    <<{Writable, Readable, Empty, Bounded} + <<!{Paused, Full}
  # support reinitialization
  if not ward.queue.isNil:
    pause ward
    while ward.queue.pop.isNil:
      discard
    reset ward.queue
  store(ward.state, flags, order=moSequentiallyConsistent)
  {.warning: "rare case, lazy; could save a store here".}
  if 0 == size:
    ward.state.enable Full
  store(ward.size, size, order=moSequentiallyConsistent)
  ward.queue = queue

proc newWard*[T](): Ward[T] =
  initWard(result, newLoonyQueue[T]())

proc newWard*[T](size: Positive = defaultInitialSize): Ward[T] =
  initWard(result, newLoonyQueue[T](), size = size)

proc performWait[T](ward: var Ward[T]; wants: FlagT): bool {.discardable.} =
  ## true if we waited, false if we already had the flags we wanted
  let state: FlagT = load(ward.state, order=moSequentiallyConsistent)
  result = state !&& wants
  if result:
    checkWait waitMask(ward.state, state, wants)

proc isEmpty*[T](ward: var Ward[T]): bool =
  assert not ward.queue.isNil
  let state = load(ward.state, order=moSequentiallyConsistent)
  result = state && <<Empty

proc waitForPushable*[T](ward: var Ward[T]): bool =
  ## true if the ward is pushable, false if it never will be
  let state = load(ward.state, order=moSequentiallyConsistent)
  if state && <<!Writable:
    result = false
  elif state && <<Paused:
    discard ward.performWait(<<!{Writable, Paused})
    result = true
  elif state && <<Full:
    discard ward.performWait(<<!{Writable, Full})
    result = true

proc waitForPoppable*[T](ward: var Ward[T]): bool =
  ## true if the ward is poppable, false if it never will be
  let state = load(ward.state, order=moSequentiallyConsistent)
  if state && <<!Readable:
    result = false
  elif state && <<Paused:
    discard ward.performWait(<<!{Readable, Paused})
    result = true
  elif state && <<Empty:
    # NOTE: short-circuit when the ward is empty and unwritable
    if state && <<Writable:
      discard ward.performWait(<<!{Writable, Readable, Empty})
      result = true
    else:
      result = false

proc unboundedPush[T](ward: var Ward[T]; item: sink T): WardFlag =
  ## push an item without regard to bounds
  push(ward.queue, move item)
  result = Readable
  # optimistically declare the ward un-empty; a lost
  # race here simply wakes a waiter harmlessly
  if disable(ward.state, Empty):
    discard wakeMask(ward.state, <<!Empty, 1)

proc markFull[T](ward: var Ward[T]): WardFlag =
  ## mark the ward as full and wake a waiter
  result = Full
  if enable(ward.state, Full):
    discard wakeMask(ward.state, <<Full, 1)

proc performPush[T](ward: var Ward[T]; item: sink T): WardFlag =
  ## safely push an item onto the ward; returns Readable
  ## if successful, else Full or Interrupt
  # XXX: runtime check for boundedness
  if <<!Bounded in ward.state:
    return unboundedPush(ward, item)
  # otherwise, we're bounded and need to claim a slot
  while true:
    var prior = 1
    # try to claim the last slot, and assign `prior`
    if compareExchange(ward.size, prior, 0, order = moSequentiallyConsistent):
      # we won the right to safely push
      result = unboundedPush(ward, item)
      # as expected, we're full
      discard ward.markFull()
      # XXX: we have some information about the queue: it's full
      break
    elif prior == 0:
      # surprise, we're full
      result = Full
      break
    elif compareExchange(ward.size, prior, prior - 1,
                         order = moSequentiallyConsistent):
      result = unboundedPush(ward, item)
      # XXX: we have some information about the queue:
      # it's readable, not empty, not full
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

proc tryPush*[T](ward: var Ward[T]; item: var T): WardFlag =
  ## fast success/fail push of item
  let state = load(ward.state, order=moSequentiallyConsistent)
  if state && <<!Writable:
    Writable
  elif state && <<Full:
    Full
  elif state && <<Paused:
    Paused
  else:
    ward.performPush(move item)

proc push*[T](ward: var Ward[T]; item: var T): WardFlag =
  ## blocking push of an item
  while true:
    result = ward.tryPush(item)
    case result
    of Readable, Writable:
      break
    of Full:
      discard ward.performWait(<<!{Writable, Full})
    of Paused:
      discard ward.performWait(<<!{Writable, Paused})
    else:
      discard

proc markEmpty[T](ward: var Ward[T]): WardFlag =
  ## mark the ward as empty; if it's also unwritable,
  ## then mark it as unreadable and wake everyone up.
  let state = load(ward.state, order=moSequentiallyConsistent)
  # NOTE: short-circuit when the ward is empty and unwritable
  if state && <<!Writable:
    result = Readable
    var woke = false
    woke = woke or enable(ward.state, Empty)
    woke = woke or disable(ward.state, Readable)
    if woke:
      wakeMask(ward.state, <<Empty || <<!{Readable, Writable})
  else:
    result = Empty
    if enable(ward.state, Empty):
      discard wakeMask(ward.state, <<Empty, 1)

proc unboundedPop[T](ward: var Ward[T]; item: var T): WardFlag =
  ## pop an item without regard to bounds
  item = pop(ward.queue)
  if item.isNil:
    result = ward.markEmpty()
  else:
    result = Writable

proc performPop[T](ward: var Ward[T]; item: var T): WardFlag =
  ## safely pop an item from the ward; returns Writable
  result = unboundedPop(ward, item)
  if Writable == result:
    # XXX: runtime check for boundedness
    if <<Bounded in ward.state:
      let count = fetchAdd(ward.size, 1, order = moSequentiallyConsistent)
      if 0 == count:
        if disable(ward.state, Full):
          discard wakeMask(ward.state, <<!Full, 1)

proc tryPop*[T](ward: var Ward[T]; item: var T): WardFlag =
  ## fast success/fail pop of item
  let state = load(ward.state, order=moSequentiallyConsistent)
  if state && <<!Readable:
    Readable
  elif state && <<Empty:
    Empty
  elif state && <<Paused:
    Paused
  else:
    ward.performPop(item)

proc pop*[T](ward: var Ward[T]; item: var T): WardFlag =
  ## blocking pop of an item
  while true:
    result = ward.tryPop(item)
    case result
    of Readable, Writable:
      break
    of Empty:
      discard ward.performWait(<<!{Readable, Empty, Writable})
    of Paused:
      discard ward.performWait(<<!{Readable, Paused})
    else:
      discard

proc closeRead*[T](ward: var Ward[T]) =
  if disable(ward.state, Readable):
    wakeMask(ward.state, <<!Readable)

proc closeWrite*[T](ward: var Ward[T]) =
  if disable(ward.state, Writable):
    wakeMask(ward.state, <<!Writable)

proc pause*[T](ward: var Ward[T]) =
  if enable(ward.state, Paused):
    wakeMask(ward.state, <<Paused)

proc resume*[T](ward: var Ward[T]) =
  if disable(ward.state, Paused):
    wakeMask(ward.state, <<!Paused)

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
    let state = load(ward.state, order=moSequentiallyConsistent)
    if <<Empty in state:
      break
    discard waitMask(ward.state, state, <<Empty)

proc waitForFull*[T](ward: var Ward[T]) =
  while true:
    let state = load(ward.state, order=moSequentiallyConsistent)
    if <<Full in state:
      break
    checkWait waitMask(ward.state, state, <<Full)

proc state*[T](ward: var Ward[T]): FlagT =
  load(ward.state, order=moSequentiallyConsistent)
