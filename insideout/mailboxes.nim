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
  MailboxObj[T: ref or ptr or void] {.packed.} = object
    when T isnot void:
      queue: LoonyQueue[T]
      size: Atomic[int]
    pad32: uint32
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

proc pause*[T](mail: Mailbox[T])
proc resume*[T](mail: Mailbox[T])

proc clear*[T](mail: Mailbox[T]) =
  when T isnot void:
    if not mail[].queue.isNil:
      while not pop(mail[].queue).isNil:
        discard

proc reveal*[T](mail: MailboxObj[T]): string =
  $cast[uint](addr mail) & " : " & $cast[uint](addr mail.state)

proc reveal*[T](mail: Mailbox[T]): string =
  mail[].reveal


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
  let dirty = flags != 0
  if dirty:
    try:
      checkpoint "destroying mail.state at", mail.reveal
      checkpoint "mail.queue nil?", mail.queue.isNil
    except IOError:
      discard
  if 0 != (flags and <<Bounded):
    put(mail.state, boundedFlags)
  else:
    put(mail.state, unboundedFlags)
  if dirty:
    # wake all waiters on the flags in order to free any
    # queued waiters in kernel space
    checkWake wake(mail.state)
    if not mail.queue.isNil:
      while not pop(mail.queue).isNil:
        discard
    reset mail.queue
    store(mail.size, 0, order = moSequentiallyConsistent)
    try:
      checkpoint "destroyed mail.state at", mail.reveal
    except IOError:
      discard

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

proc newMailbox*[T](): Mailbox[T] =
  ## create a new mailbox limited only by available memory
  new result
  when T is void:
    put(result[].state, voidFlags)
  else:
    put(result[].state, unboundedFlags)
    # support reinitialization
    if not result[].queue.isNil:
      while not result[].queue.pop.isNil:
        discard
      reset result[].queue
    result[].queue = newLoonyQueue[T]()
    store(result[].size, 0, order = moSequentiallyConsistent)
    resume result
    checkWake wake(result[].state)
    try:
      checkpoint "initialized mail.state at", result.reveal
    except IOError:
      discard

proc newMailbox*[T: not void](size: Positive): Mailbox[T] =
  ## create a new mailbox which can hold `size` items
  new result
  put(result[].state, boundedFlags)
  # support reinitialization
  if not result[].queue.isNil:
    while not result[].queue.pop.isNil:
      discard
    reset result[].queue
  result[].queue = newLoonyQueue[T]()
  store(result[].size, size, order = moSequentiallyConsistent)
  if 0 == size:
    result[].state.enable Full
  resume result
  checkWake wake(result[].state)
  try:
    checkpoint "initialized mail.state at", result.reveal
  except IOError:
    discard

proc performWait[T](mail: Mailbox[T]; has: FlagT; wants: FlagT): bool {.discardable.} =
  ## true if we had to wait; false otherwise
  result = 0 == (has and wants)
  if result:
    checkWait waitMask(mail[].state, has, wants)

proc isEmpty*[T](mail: Mailbox[T]): bool =
  when T is void:
    true
  else:
    assert not mail[].queue.isNil
    let state = get mail[].state
    result = state && <<Empty

proc isFull*[T](mail: Mailbox[T]): bool =
  when T is void:
    true
  else:
    assert not mail[].queue.isNil
    let state = get mail[].state
    result = state && <<Empty

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

proc unboundedPush[T](mail: Mailbox[T]; item: sink T): WardFlag =
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

proc performPush[T](mail: Mailbox[T]; item: sink T): WardFlag =
  ## safely push an item onto the mailbox; returns Readable
  ## if successful, else Full or Interrupt
  # XXX: runtime check for boundedness
  if <<!Bounded in mail[].state:
    return unboundedPush(mail, item)
  # otherwise, we're bounded and need to claim a slot
  while true:
    var prior = 1
    # try to claim the last slot, and assign `prior`
    atomicThreadFence ATOMIC_SEQ_CST
    if compareExchange(mail[].size, prior, 0, order = moSequentiallyConsistent):
      atomicThreadFence ATOMIC_SEQ_CST
      # we won the right to safely push
      result = unboundedPush(mail, item)
      # as expected, we're full
      discard mail.markFull()
      # XXX: we have some information about the queue: it's full
      break
    elif prior == 0:
      # surprise, we're full
      result = Full
      break
    elif compareExchange(mail[].size, prior, prior - 1,
                         order = moSequentiallyConsistent):
      atomicThreadFence ATOMIC_SEQ_CST
      result = unboundedPush(mail, item)
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

proc tryPush*[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## fast success/fail push of item
  assert not mail.isNil
  let state = get mail[].state
  if state && <<!Writable:
    Unwritable
  elif state && <<Full:
    Full
  elif state && <<Paused:
    Paused
  else:
    mail.performPush(move item)

proc push*[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## blocking push of an item
  assert not mail.isNil
  while true:
    result = mail.tryPush(item)
    case result
    of Delivered, Unwritable:
      break
    of Full:
      discard mail.performWait(get(mail[].state), <<!{Writable, Full})
    of Paused:
      discard mail.performWait(get(mail[].state), <<!{Writable, Paused})
    of Interrupt:
      break
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
    # XXX: runtime check for boundedness
    if <<Bounded in mail[].state:
      atomicThreadFence ATOMIC_SEQ_CST
      let count = fetchAdd(mail[].size, 1, order = moSequentiallyConsistent)
      atomicThreadFence ATOMIC_SEQ_CST
      if 0 == count:
        if mail[].state.disable Full:
          checkWake wakeMask(mail[].state, <<!Full)

proc tryPop*[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## fast success/fail pop of item
  assert not mail.isNil
  let state = get mail[].state
  if state && <<!Readable:
    Unreadable
  elif state && <<Empty:
    Empty
  elif state && <<Paused:
    Paused
  else:
    mail.performPop(item)

proc pop*[T](mail: Mailbox[T]; item: var T): WardFlag =
  ## blocking pop of an item
  assert not mail.isNil
  while true:
    result = mail.tryPop(item)
    case result
    of Unreadable, Received:
      break
    of Empty:
      discard mail.performWait(get(mail[].state), <<!{Readable, Empty})
    of Paused:
      discard mail.performWait(get(mail[].state), <<!{Readable, Paused})
    of Interrupt:
      break
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

proc tryRecv*[T](mail: Mailbox[T]; message: var T): WardFlag =
  ## non-blocking attempt to pop an item from the mailbox;
  ## true if it worked
  assert not mail.isNil
  let state = mail.state
  if state && <<!Readable:
    Readable
  elif state && <<Paused:
    Paused
  elif state && <<Empty:
    Empty
  else:
    tryPop(mail, message)

proc send*[T](mail: Mailbox[T]; item: sink T) =
  ## blocking push of an item into the mailbox
  assert not mail.isNil
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

proc trySend*[T](mail: Mailbox[T]; item: sink T): WardFlag =
  ## non-blocking attempt to push an item into the mailbox;
  ## true if it worked
  assert not mail.isNil
  when not defined(danger):
    if unlikely item.isNil:
      raise ValueError.newException "attempt to send nil"
  let state = mail.state
  if state && <<!Writable:
    Writable
  elif state && <<Paused:
    Paused
  elif state && <<Full:
    Full
  else:
    tryPush(mail, item)

proc state*[T](mail: Mailbox[T]): FlagT {.deprecated.} =
  assert not mail.isNil
  get mail[].state

template disablePush*[T](mail: Mailbox[T]) {.deprecated.} =
  closeWrite(mail)

template disablePop*[T](mail: Mailbox[T]) {.deprecated.} =
  closeWrite(mail)
