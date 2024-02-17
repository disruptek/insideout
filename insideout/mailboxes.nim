import std/atomics
import std/hashes
import std/os
import std/posix
import std/sets
import std/strutils

import pkg/loony
from pkg/balls import checkpoint

import insideout/futex
import insideout/atomic/flags
import insideout/atomic/refs
export refs

type
  WardFlag* {.size: 2.} = enum       ## flags for mail[].state
    Interrupt = 0  #    1 / 65536     tiny type overload for EINTR
    Paused    = 1  #    2 / 131072
    Empty     = 2  #    4 / 262144
    Full      = 3  #    8 / 524288
    Readable  = 4  #   16 / 1048576
    Writable  = 5  #   32 / 2097152
    Bounded   = 6  #   64 / 4194304
  FlagT = uint32

  # we need a .byref. while the object is so small
  MailboxObj[T: ref or ptr or void] {.byref.} = object
    when T isnot void:
      queue: LoonyQueue[T]
      size: Atomic[uint32]
      capacity: Atomic[uint32]
    state: AtomicFlags32
  Mailbox*[T] = AtomicRef[MailboxObj[T]]

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

proc `=copy`*[T](dest: var MailboxObj[T]; src: MailboxObj[T]) {.error.}

proc resume*[T](mail: Mailbox[T])

proc reveal*[T](mail: MailboxObj[T]): string =
  $T & " " & cast[int](addr mail.state).toHex.toLowerAscii

proc reveal*[T](mail: Mailbox[T]): string =
  let x = cast[int](addr mail[].state)
  let y = cast[int](address mail)
  let z = cast[int](addr mail[])
  #checkpoint "reveal: state/ptr/addr", x.toHex, y.toHex, z.toHex, y-x
  assert y == z
  when T isnot void:
    assert x - y == 16
  let s = $T & " " & cast[int](addr mail[].state).toHex.toLowerAscii
  cast[int](address mail).toHex.toLowerAscii & " -> " & s

proc `=destroy`*(mail: var MailboxObj[void]) =
  # reset the flags so that the subsequent wake will
  # not be ignored for any reason
  put(mail.state, voidFlags)
  # wake all waiters on the flags in order to free any
  # queued waiters in kernel space
  checkWake wake(mail.state)

proc `=destroy`*[T: not void](mail: var MailboxObj[T]) =
  # reset the flags so that the subsequent wake will
  # not be ignored for any reason
  let flags = get mail.state
  when false:
    try:
      checkpoint "destroying mail:", mail.reveal
    except IOError:
      discard
  if 0 != (flags and <<Bounded):
    put(mail.state, boundedFlags)
  else:
    put(mail.state, unboundedFlags)
  # wake all waiters on the flags in order to free any
  # queued waiters in kernel space
  checkWake wake(mail.state)
  if not mail.queue.isNil:
    while not pop(mail.queue).isNil:
      discard
  reset mail.queue
  store(mail.capacity, 0, order = moSequentiallyConsistent)
  store(mail.size, 0, order = moSequentiallyConsistent)

proc hash*(mail: Mailbox): Hash =
  ## whatfer inclusion in a table, etc.
  mixin address
  hash cast[int](address mail)

proc `==`*[T](a: Mailbox[T]; b: Mailbox[T]): bool =
  ## two mailboxes are identical if they have the same hash
  mixin hash
  hash(a) == hash(b)

proc `$`*[T](mail: Mailbox[T]): string =
  if mail.isNil:
    result = "<box["
    result.add $T
    result.add "]:nil>"
  else:
    result = "<box["
    result.add $T
    result.add "]:"
    result.add:
      hash(mail).int.toHex(6)
    result.add: "#"
    result.add: $mail.owners
    result.add ">"

when false:
  proc newMailbox*[T: void](): Mailbox[T] =
    new result
    put(result[].state, voidFlags)
  #proc newMailbox*[T: not void](): Mailbox[T] =

proc newMailbox*[T: not void](capacity: uint32): Mailbox[T] =
  ## create a new mailbox which can hold `capacity` items
  new result
  put(result[].state, boundedFlags)
  # support reinitialization
  if not result[].queue.isNil:
    while not result[].queue.pop.isNil:
      discard
    reset result[].queue
  result[].queue = newLoonyQueue[T]()
  store(result[].capacity, capacity, order = moSequentiallyConsistent)
  store(result[].size, 0, order = moSequentiallyConsistent)
  if 0 == capacity:
    result[].state.enable Full
  resume result
  discard checkWake wake(result[].state)

proc newMailbox*[T](): Mailbox[T] =
  ## create a new mailbox (likely) limited only by available memory
  when T is void:
    new result
    put(result[].state, voidFlags)
  else:
    result = newMailbox[T](high uint32)

proc performWait[T](mail: Mailbox[T]; has: FlagT; wants: FlagT): bool {.discardable.} =
  ## true if we had to wait; false otherwise
  result = 0 == (has and wants)
  if result:
    # FIXME: stupid workaround
    checkWait waitMask(mail[].state, has, wants, 0.01)

proc isEmpty*[T](mail: Mailbox[T]): bool =
  assert not mail.isNil
  when T is void:
    true
  else:
    assert not mail[].queue.isNil
    let state = get mail[].state
    result = state && <<Empty

proc isFull*[T](mail: Mailbox[T]): bool =
  assert not mail.isNil
  when T is void:
    true
  else:
    assert not mail[].queue.isNil
    let state = get mail[].state
    result = state && <<Full

proc waitForPushable*[T](mail: Mailbox[T]): bool =
  ## true if the mailbox is pushable, false if it never will be
  let state = get mail[].state
  if state && <<!Writable:
    result = false
  elif state && <<Paused:
    result = true
    discard mail.performWait(state, <<!{Writable, Paused})
  elif state && <<Full:
    # NOTE: short-circuit when the mailbox is full and unreadable
    result = state && <<Readable
    if result:
      discard mail.performWait(state, <<!{Writable, Readable, Full})
  else:
    result = true

proc waitForPoppable*[T](mail: Mailbox[T]): bool =
  ## true if the mailbox is poppable, false if it never will be
  let state = get mail[].state
  if state && <<!Readable:
    result = false
  elif state && <<Paused:
    result = true
    discard mail.performWait(state, <<!{Readable, Paused})
  elif state && <<Empty:
    # NOTE: short-circuit when the mailbox is empty and unwritable
    result = state && <<Writable
    if result:
      discard mail.performWait(state, <<!{Writable, Readable, Empty})
  else:
    result = true

proc unboundedPush[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## push an item without regard to bounds
  push(mail[].queue, move item)
  result = Readable
  # optimistically declare the mailbox un-empty; a lost
  # race here simply wakes a waiter harmlessly
  if disable(mail[].state, Empty):
    checkWake wakeMask(mail[].state, <<!Empty)

proc markFull[T](mail: Mailbox[T]): WardFlag =
  ## mark the mailbox as full and wake a waiter
  result = Full
  if enable(mail[].state, Full):
    checkWake wakeMask(mail[].state, <<Full)

proc performPush[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## safely push an item onto the mailbox; returns Readable
  ## if successful, else Full or Interrupt
  when T is void: return Full
  # we're bounded and need to claim a slot
  let capacity = load(mail[].capacity, order = moSequentiallyConsistent)
  var prior = capacity-1  # aim for the last slot
  while true:
    # try to claim the last slot, and assign `prior`
    if compareExchange(mail[].size, prior, capacity, order = moSequentiallyConsistent):
      # we won the right to safely push
      result = unboundedPush(mail, item)
      # as expected, we're full
      discard mail.markFull()
      break
    elif prior == capacity:
      # surprise, we're full
      result = mail.markFull()
      break
    elif compareExchange(mail[].size, prior, prior + 1,
                         order = moSequentiallyConsistent):
      result = unboundedPush(mail, item)
      # we have some information about the queue:
      # it's readable, not empty, not full
      if disable(mail[].state, Empty):
        checkWake wakeMask(mail[].state, <<!Empty)
      if disable(mail[].state, Full):
        checkWake wakeMask(mail[].state, <<!Full)
      break
    else:
      # race case: failed to win our slot
      result = Interrupt
      prior = capacity-1   # reset aim
      when defined(danger):
        # spin to avoid a context switch
        discard
      else:
        # bomb out to try again later
        break

proc trySend*[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## non-blocking attempt to push an item into the mailbox
  assert not mail.isNil
  when T is void: return Full
  when not defined(danger):
    if unlikely item.isNil:
      raise ValueError.newException "attempt to send nil"
  let state = get mail[].state
  if state && <<!Writable:
    Unwritable
  elif state && <<Paused:
    Paused
  elif state && <<Full:
    Full
  else:
    mail.performPush(item)

proc push[T](mail: Mailbox[T]; item: sink T): WardFlag =
  ## blocking push of an item
  assert not mail.isNil
  while true:
    let state = get mail[].state
    result = mail.trySend(item)
    case result
    of Delivered, Unwritable, Interrupt:
      break
    of Full:
      discard mail.performWait(state, <<!{Writable, Full})
    of Paused:
      discard mail.performWait(state, <<!{Writable, Paused})
    else:
      discard

proc markEmpty[T](mail: Mailbox[T]): WardFlag =
  ## mark the mailbox as empty; if it's also unwritable,
  ## then mark it as unreadable and wake everyone up.
  let state = get mail[].state
  # NOTE: short-circuit when the mailbox is empty and unwritable
  if state && <<!Writable:
    result = Unreadable
    var woke = false
    woke = woke or enable(mail[].state, Empty)
    woke = woke or disable(mail[].state, Readable)
    if woke:
      checkWake wakeMask(mail[].state, <<Empty + <<!{Readable, Writable})
  else:
    result = Empty
    if enable(mail[].state, Empty):
      checkWake wakeMask(mail[].state, <<Empty)

proc unboundedPop[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## pop an item without regard to bounds
  item = pop(mail[].queue)
  if item.isNil:
    result = mail.markEmpty()
  else:
    result = Received

proc performPop[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## safely pop an item from the mailbox; returns Writable
  result = unboundedPop(mail, item)
  if Received == result:
    discard fetchSub(mail[].size, 1, order = moSequentiallyConsistent)
    # optimistically declare the mailbox un-full; a lost
    # race here simply wakes a waiter harmlessly
    if disable(mail[].state, Full):
      checkWake wakeMask(mail[].state, <<!Full)

proc tryRecv*[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## non-blocking attempt to pop an item from the mailbox
  assert not mail.isNil
  when T is void: return Empty
  let state = get mail[].state
  if state && <<!Readable:
    Unreadable
  elif state && <<Paused:
    Paused
  elif state && <<Empty:
    Empty
  else:
    mail.performPop(item)

proc pop[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## blocking pop of an item
  assert not mail.isNil
  while true:
    let state = get mail[].state
    result = mail.tryRecv(item)
    case result
    of Unreadable, Received, Interrupt:
      break
    of Paused:
      discard mail.performWait(state, <<!{Readable, Paused})
    of Empty:
      if mail[].queue.isEmpty:
        discard mail.performWait(state, <<!{Readable, Empty})
      elif disable(mail[].state, Empty):
        checkWake wakeMask(mail[].state, <<!Empty)
    else:
      discard

proc closeRead*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  if disable(mail[].state, Readable):
    checkWake wakeMask(mail[].state, <<!Readable)

proc closeWrite*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  if disable(mail[].state, Writable):
    checkWake wakeMask(mail[].state, <<!Writable)

proc pause*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  if enable(mail[].state, Paused):
    checkWake wakeMask(mail[].state, <<Paused)

proc resume*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  if disable(mail[].state, Paused):
    checkWake wakeMask(mail[].state, <<!Paused)

proc clear*[T](mail: Mailbox[T]) =
  when T isnot void:
    if not mail[].queue.isNil:
      while not pop(mail[].queue).isNil:
        discard

proc waitForEmpty*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  while true:
    let state = get mail[].state
    if state && <<Empty:
      break
    else:
      if not mail.performWait(state, <<Empty):
        break

proc waitForFull*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  while true:
    let state = get mail[].state
    if state && <<Full:
      break
    else:
      if not mail.performWait(state, <<Full):
        break

proc recv*[T](mail: Mailbox[T]): T =
  ## blocking pop of an item from the mailbox
  assert not mail.isNil
  when T is void: return Empty
  while true:
    case pop(mail, result)
    of Received:
      break
    of Unreadable:
      raise ValueError.newException "unreadable mailbox; state at " & reveal(mail)
    of Interrupt:
      raise IOError.newException "interrupted"
    else:
      discard

proc send*[T](mail: Mailbox[T]; item: sink T) =
  ## blocking push of an item into the mailbox
  assert not mail.isNil
  when T is void: return Full
  when not defined(danger):
    if unlikely item.isNil:
      raise ValueError.newException "nil message"
  while true:
    case push(mail, item)
    of Delivered:
      break
    of Unwritable:
      raise ValueError.newException "unwritable mailbox"
    of Interrupt:
      raise IOError.newException "interrupted"
    else:
      discard

proc state*[T](mail: Mailbox[T]): FlagT {.deprecated.} =
  assert not mail.isNil
  get mail[].state

template disablePush*[T](mail: Mailbox[T]) {.deprecated.} =
  closeWrite(mail)

template disablePop*[T](mail: Mailbox[T]) {.deprecated.} =
  closeWrite(mail)
