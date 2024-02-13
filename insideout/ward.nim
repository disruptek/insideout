import std/atomics
import std/os
import std/posix
import std/sets

import pkg/loony

import insideout/futex
import insideout/atomic/flags

type
  WardFlag* {.size: 2.} = enum       ## flags for ward state
    Interrupt = 0  #    1 / 65536     tiny type overload for EINTR
    Paused    = 1  #    2 / 131072
    Empty     = 2  #    4 / 262144
    Full      = 3  #    8 / 524288
    Readable  = 4  #   16 / 1048576
    Writable  = 5  #   32 / 2097152
    Bounded   = 6  #   64 / 4194304
  FlagT = uint32
  Ward*[T: ref or ptr or void] {.packed.} = object
    when T isnot void:
      queue: LoonyQueue[T]
      size: Atomic[int]
    pad32: uint32
    state: AtomicFlags32

const
  Received* = Writable
  Delivered* = Readable
  Unreadable* = Readable
  Unwritable* = Writable

const voidFlags =
  <<{Interrupt, Writable, Readable, Empty, Full, Bounded} + <<!{Paused}
const unboundedFlags =
  <<{Interrupt, Writable, Readable, Empty, Paused} + <<!{Full, Bounded}
const boundedFlags =
  <<{Interrupt, Writable, Readable, Empty, Paused, Bounded} + <<!{Full}
proc pause*[T](ward: var Ward[T])
proc resume*[T](ward: var Ward[T])

proc clear*[T](ward: var Ward[T]) =
  when T isnot void:
    if not ward.queue.isNil:
      while not pop(ward.queue).isNil:
        discard

proc `=destroy`*(ward: var Ward[void]) =
  # reset the flags so that the subsequent wake will
  # not be ignored for any reason
  put(ward.state, voidFlags)
  # wake all waiters on the flags in order to free any
  # queued waiters in kernel space
  checkWake wake(ward.state)

proc `=destroy`*[T: not void](ward: var Ward[T]) =
  # reset the flags so that the subsequent wake will
  # not be ignored for any reason
  let flags = get ward.state
  if 0 != (flags and <<Bounded):
    put(ward.state, boundedFlags)
  else:
    put(ward.state, unboundedFlags)
  # wake all waiters on the flags in order to free any
  # queued waiters in kernel space
  checkWake wake(ward.state)
  clear ward
  reset ward.queue
  store(ward.size, 0, order = moSequentiallyConsistent)

proc initWard*[T: void](ward: var Ward[T]) =
  put(ward.state, voidFlags)

proc initWard*[T: not void](ward: var Ward[T]; queue: LoonyQueue[T]) =
  put(ward.state, unboundedFlags)
  # support reinitialization
  if not ward.queue.isNil:
    while not ward.queue.pop.isNil:
      discard
    reset ward.queue
  ward.queue = queue
  store(ward.size, 0, order = moSequentiallyConsistent)
  resume ward
  checkWake wake(ward.state)

proc initWard*[T: not void](ward: var Ward[T]; queue: LoonyQueue[T];
                            size: Positive) =
  put(ward.state, boundedFlags)
  # support reinitialization
  if not ward.queue.isNil:
    while not ward.queue.pop.isNil:
      discard
    reset ward.queue
  ward.queue = queue
  store(ward.size, size, order = moSequentiallyConsistent)
  if 0 == size:
    ward.state.enable Full
  resume ward
  checkWake wake(ward.state)

proc performWait[T](ward: var Ward[T]; has: FlagT; wants: FlagT): bool {.discardable.} =
  ## true if we had to wait; false otherwise
  result = 0 == (has and wants)
  if result:
    checkWait waitMask(ward.state, has, wants)

proc isEmpty*[T](ward: var Ward[T]): bool =
  when T is void:
    true
  else:
    assert not ward.queue.isNil
    let state = get ward.state
    result = state && <<Empty

proc isFull*[T](ward: var Ward[T]): bool =
  when T is void:
    true
  else:
    assert not ward.queue.isNil
    let state = get ward.state
    result = state && <<Empty

proc waitForPushable*[T](ward: var Ward[T]): bool =
  ## true if the ward is pushable, false if it never will be
  let state = get ward.state
  if state && <<!Writable:
    result = false
  elif state && <<Paused:
    result = true
    discard ward.performWait(state, <<!{Writable, Paused})
  elif state && <<Full:
    # NOTE: short-circuit when the ward is full and unreadable
    result = state && <<Readable
    if result:
      discard ward.performWait(state, <<!{Writable, Readable, Full})
  else:
    result = true

proc waitForPoppable*[T](ward: var Ward[T]): bool =
  ## true if the ward is poppable, false if it never will be
  let state = get ward.state
  if state && <<!Readable:
    result = false
  elif state && <<Paused:
    result = true
    discard ward.performWait(state, <<!{Readable, Paused})
  elif state && <<Empty:
    # NOTE: short-circuit when the ward is empty and unwritable
    result = state && <<Writable
    if result:
      discard ward.performWait(state, <<!{Writable, Readable, Empty})
  else:
    result = true

proc unboundedPush[T](ward: var Ward[T]; item: sink T): WardFlag =
  ## push an item without regard to bounds
  push(ward.queue, move item)
  result = Readable
  # optimistically declare the ward un-empty; a lost
  # race here simply wakes a waiter harmlessly
  if disable(ward.state, Empty):
    checkWake wakeMask(ward.state, <<!Empty)

proc markFull[T](ward: var Ward[T]): WardFlag =
  ## mark the ward as full and wake a waiter
  result = Full
  if enable(ward.state, Full):
    checkWake wakeMask(ward.state, <<Full)

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
    atomicThreadFence ATOMIC_SEQ_CST
    if compareExchange(ward.size, prior, 0, order = moSequentiallyConsistent):
      atomicThreadFence ATOMIC_SEQ_CST
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
      atomicThreadFence ATOMIC_SEQ_CST
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
  let state = get ward.state
  if state && <<!Writable:
    Unwritable
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
    of Delivered, Unwritable:
      break
    of Full:
      discard ward.performWait(get(ward.state), <<!{Writable, Full})
    of Paused:
      discard ward.performWait(get(ward.state), <<!{Writable, Paused})
    of Interrupt:
      break
    else:
      discard

proc markEmpty[T](ward: var Ward[T]): WardFlag =
  ## mark the ward as empty; if it's also unwritable,
  ## then mark it as unreadable and wake everyone up.
  let state = get ward.state
  # NOTE: short-circuit when the ward is empty and unwritable
  if state && <<!Writable:
    result = Unreadable
    var woke = false
    woke = woke or enable(ward.state, Empty)
    woke = woke or disable(ward.state, Readable)
    if woke:
      checkWake wakeMask(ward.state, <<Empty + <<!{Readable, Writable})
  else:
    result = Empty
    if enable(ward.state, Empty):
      checkWake wakeMask(ward.state, <<Empty)

proc unboundedPop[T](ward: var Ward[T]; item: var T): WardFlag =
  ## pop an item without regard to bounds
  item = pop(ward.queue)
  if item.isNil:
    result = ward.markEmpty()
  else:
    result = Received

proc performPop[T](ward: var Ward[T]; item: var T): WardFlag =
  ## safely pop an item from the ward; returns Writable
  result = unboundedPop(ward, item)
  if Received == result:
    # XXX: runtime check for boundedness
    if <<Bounded in ward.state:
      atomicThreadFence ATOMIC_SEQ_CST
      let count = fetchAdd(ward.size, 1, order = moSequentiallyConsistent)
      atomicThreadFence ATOMIC_SEQ_CST
      if 0 == count:
        if ward.state.disable Full:
          checkWake wakeMask(ward.state, <<!Full)

proc tryPop*[T](ward: var Ward[T]; item: var T): WardFlag =
  ## fast success/fail pop of item
  let state = get ward.state
  if state && <<!Readable:
    Unreadable
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
    of Unreadable, Received:
      break
    of Empty:
      discard ward.performWait(get(ward.state), <<!{Readable, Empty})
    of Paused:
      discard ward.performWait(get(ward.state), <<!{Readable, Paused})
    of Interrupt:
      break
    else:
      discard

proc closeRead*[T](ward: var Ward[T]) =
  if disable(ward.state, Readable):
    checkWake wakeMask(ward.state, <<!Readable)

proc closeWrite*[T](ward: var Ward[T]) =
  if disable(ward.state, Writable):
    checkWake wakeMask(ward.state, <<!Writable)

proc pause*[T](ward: var Ward[T]) =
  if enable(ward.state, Paused):
    checkWake wakeMask(ward.state, <<Paused)

proc resume*[T](ward: var Ward[T]) =
  if disable(ward.state, Paused):
    checkWake wakeMask(ward.state, <<!Paused)

proc waitForEmpty*[T](ward: var Ward[T]) =
  while true:
    let state = get ward.state
    if state && <<Empty:
      break
    else:
      if not ward.performWait(state, <<Empty):
        break

proc waitForFull*[T](ward: var Ward[T]) =
  while true:
    let state = get ward.state
    if state && <<Full:
      break
    else:
      if not ward.performWait(state, <<Full):
        break

proc state*[T](ward: var Ward[T]): FlagT =
  get ward.state
