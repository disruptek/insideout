import std/atomics
import std/hashes
import std/os
import std/posix
import std/sets
import std/strutils

import pkg/cps
import pkg/loony

import insideout/spec
import insideout/futexes
export FutexError

import insideout/atomic/flags
import insideout/atomic/refs
export refs

export insideoutSafeMode

when insideoutSafeMode:
  import std/rlocks
  type
    ListNode[T] {.byref.} = ref object
      value: T
      next: ListNode[T]
    List[T] {.byref.} = object
      head: ListNode[T]
      tail: ListNode[T]
    MailboxObj[T: ref or ptr or void] = object
      state: AtomicFlags32
      reads: Atomic[uint64]
      writes: Atomic[uint64]
      readers: Atomic[uint32]
      writers: Atomic[uint32]
      lock: RLock
      size: Atomic[uint32]
      capacity: Atomic[uint32]
      when T isnot void:
        list: List[T]
    Mailbox*[T] = AtomicRef[MailboxObj[T]]
else:
  type
    # we need a .byref. while the object is so small
    MailboxObj[T: ref or ptr or void] = object
      state: AtomicFlags32
      reads: Atomic[uint64]
      writes: Atomic[uint64]
      readers: Atomic[uint32]
      writers: Atomic[uint32]
      size: Atomic[uint32]
      capacity: Atomic[uint32]
      when T isnot void:
        queue: LoonyQueue[T]
    Mailbox*[T] = AtomicRef[MailboxObj[T]]

type
  MailFlag* {.size: 2.} = enum       ## flags for mail[].state
    Interrupt = 0  #    1 / 65536     tiny type overload for EINTR
    Paused    = 1  #    2 / 131072
    Empty     = 2  #    4 / 262144
    Full      = 3  #    8 / 524288
    Readable  = 4  #   16 / 1048576
    Writable  = 5  #   32 / 2097152
    Bounded   = 6  #   64 / 4194304

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

proc len*[T](mail: Mailbox[T]): uint32 =
  assert not mail.isNil
  result = load(mail[].size, order = moAcquire)
  let w = load(mail[].writers, order = moAcquire)
  #if w != 0: debug "writers: ", w
  result += w
  let r = load(mail[].readers, order = moAcquire)
  #if r != 0: debug "readers: ", r
  result -= r

proc capacity*[T](mail: Mailbox[T]): uint32 =
  assert not mail.isNil
  result = load(mail[].capacity, order = moAcquire)

when insideoutSafeMode:
  proc count[T](mail: var MailboxObj[T]): uint32 =
    withRLock mail.lock:
      var node = mail.list.head
      while not node.isNil:
        inc result
        node = node.next

proc `capacity=`*[T](mail: var Mailbox[T]; size: uint32) =
  assert not mail.isNil
  store(mail[].capacity, size, order = moRelease)

proc destruct[T](mail: var MailboxObj[T]) =
  store(mail.capacity, 0, order = moSequentiallyConsistent)
  store(mail.size, 0, order = moSequentiallyConsistent)
  store(mail.reads, 0, order = moSequentiallyConsistent)
  store(mail.writes, 0, order = moSequentiallyConsistent)
  # this should ruin it sufficiently
  store(mail.readers, 0, order = moSequentiallyConsistent)
  store(mail.writers, 0, order = moSequentiallyConsistent)

proc `=destroy`(mail: var MailboxObj[void]) {.raises: [].} =
  # reset the flags so that the subsequent wake will
  # not be ignored for any reason
  put(mail.state, voidFlags)
  lastWake mail.state
  destruct mail

proc `=destroy`[T: not void](mail: var MailboxObj[T]) =
  # reset the flags so that the subsequent wake will
  # not be ignored for any reason
  let flags = get mail.state
  if 0 != (flags and <<Bounded):
    put(mail.state, boundedFlags)
  else:
    put(mail.state, unboundedFlags)
  lastWake mail.state
  destruct mail
  when insideoutSafeMode:
    withRLock mail.lock:
      if not mail.list.tail.isNil:
        mail.list.tail.next = nil
      reset mail.list
    deinitRLock mail.lock
  else:
    if not mail.queue.isNil:
      while not pop(mail.queue).isNil:
        discard
    reset mail.queue

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

proc construct[T](mail: var MailboxObj[T]; capacity: uint32) =
  let capacity: uint32 = when T is void: 0 else: capacity
  store(mail.capacity, capacity, order = moSequentiallyConsistent)
  store(mail.size, 0, order = moSequentiallyConsistent)
  store(mail.reads, 0, order = moSequentiallyConsistent)
  store(mail.writes, 0, order = moSequentiallyConsistent)
  # a valid bitmask for futex use
  store(mail.readers, 1, order = moSequentiallyConsistent)
  store(mail.writers, 1, order = moSequentiallyConsistent)
  if 0 == capacity:
    discard mail.state.enable Full

proc newMailbox*[T: not void](capacity: uint32): Mailbox[T] =
  ## create a new mailbox which can hold `capacity` items
  new result
  put(result[].state, boundedFlags)
  # support reinitialization
  when insideoutSafeMode:
    initRLock result[].lock
    reset result[].list
  else:
    if not result[].queue.isNil:
      while not result[].queue.pop.isNil:
        discard
      reset result[].queue
    result[].queue = newLoonyQueue[T]()
  construct(result[], capacity)
  resume result
  discard checkWake wake(result[].state)

proc newMailbox*[T](): Mailbox[T] =
  ## create a new mailbox (likely) limited only by available memory
  when T is void:  # workaround for nimskull
    new result
    put(result[].state, voidFlags)
    construct(result[], 0)
    resume result
    discard checkWake wake(result[].state)
  else:
    result = newMailbox[T](high uint32)

proc interrupt*[T](mail: Mailbox[T]; count = high(uint32)) =
  ## interrupt some threads waiting on the mailbox
  assert not mail.isNil
  discard mail[].state.enable Interrupt
  # always wake the specified number of waiters
  checkWake wakeMask(mail[].state, <<Interrupt, count = count)

proc performWait[T](mail: Mailbox[T]; has: uint32; wants: uint32): bool {.discardable.} =
  ## true if we had to wait; false otherwise
  let wants = wants and <<Interrupt  # always wake on interrupt
  result = 0 == (has and wants)
  if result:
    let e = checkWait waitMask(mail[].state, has, wants)
    case e
    of EINTR:
      debug "INTERRUPT"
    else:
      discard
    # consume any Interrupt and wake a single interruptee
    if mail[].state.disable Interrupt:
      checkWake wakeMask(mail[].state, <<!Interrupt, count = 1)

proc isEmpty*[T](mail: Mailbox[T]): bool =
  assert not mail.isNil
  let state = get mail[].state
  result = state && <<Empty

proc isFull*[T](mail: Mailbox[T]): bool =
  assert not mail.isNil
  let state = get mail[].state
  result = state && <<Full

proc waitForPushable*[T](mail: Mailbox[T]): bool =
  ## true if the mailbox is pushable, false if it never will be
  while true:
    let state = get mail[].state
    if state && <<Paused:
      discard mail.performWait(state, <<!{Writable, Readable, Paused})
    elif state && <<!Writable:
      return false
    # NOTE: short-circuit when the mailbox is full and unreadable
    elif state && <<!Readable:            # it cannot be drained, but
      return mail.len < mail.capacity     # can it be filled?
    elif state && <<Full:
      discard mail.performWait(state, <<!{Writable, Readable, Full})
    else:
      return true

proc waitForPoppable*[T](mail: Mailbox[T]): bool =
  ## true if the mailbox is poppable, false if it never will be
  while true:
    let state = get mail[].state
    if state && <<Paused:
      discard mail.performWait(state, <<!{Readable, Writable, Paused})
    elif state && <<!Readable:
      return false
    # NOTE: short-circuit when the mailbox is empty and unwritable
    elif state && <<!Writable:            # it cannot be filled, but
      return mail.len > 0                 # can it be drained?
    elif state && <<Empty:
      discard mail.performWait(state, <<!{Readable, Writable, Empty})
    else:
      return true

proc markEmpty[T](mail: var MailboxObj[T]): MailFlag =
  ## mark the mailbox as empty; if it's also unwritable,
  ## then mark it as unreadable and wake everyone up.
  let state = get mail.state
  # NOTE: short-circuit when the mailbox is empty and unwritable
  if state && <<!Writable:
    result = Unreadable
    var woke = false
    woke = woke or enable(mail.state, Empty)
    woke = woke or disable(mail.state, Readable)
    if woke:
      checkWake wakeMask(mail.state, <<Empty + <<!Readable)
  else:
    result = Empty
    if enable(mail.state, Empty):
      checkWake wakeMask(mail.state, <<Empty)

proc markFull[T](mail: var MailboxObj[T]): MailFlag =
  ## mark the mailbox as full; if it's also unreadable,
  ## then mark it as unwritable and wake everyone up.
  let state = get mail.state
  # NOTE: short-circuit when the mailbox is full and unreadable
  if state && <<!Readable:
    result = Unwritable
    var woke = false
    woke = woke or enable(mail.state, Full)
    woke = woke or disable(mail.state, Writable)
    if woke:
      checkWake wakeMask(mail.state, <<Full + <<!Writable)
  else:
    result = Full
    if enable(mail.state, Full):
      checkWake wakeMask(mail.state, <<Full)

when insideoutSafeMode:
  proc unboundedPush[T](mail: var MailboxObj[T]; item: var T): MailFlag =
    withRLock mail.lock:
      when item isnot Continuation:
        debug "add item ", item[]
      var node = ListNode[T](value: move item)
      if mail.list.head.isNil:
        node.next = node
        mail.list.head = node
      else:
        node.next = mail.list.head
        mail.list.tail.next = node
      mail.list.tail = move node
      result = Delivered
else:
  proc unboundedPush[T](mail: var MailboxObj[T]; item: var T): MailFlag =
    ## push an item without regard to bounds
    mail.queue.unsafePush(move item)
    #mail.queue.push(move item)
    result = Delivered

proc performPush[T](mail: Mailbox[T]; item: var T): MailFlag =
  ## safely push an item onto the mailbox; returns Delivered
  ## if successful, else Full or Interrupt
  let capacity = mail.capacity
  if capacity <= 0: return Full  # no room at the inn
  let size = mail.len
  if size >= capacity: return Full
  when insideoutSafeMode:
    debug "acquire"
    acquire mail[].lock
    let mo = moSequentiallyConsistent
  else:
    let mo = moRelaxed
  discard fetchAdd(mail[].writers, 1, order = mo)
  result = unboundedPush(mail[], item)
  #assert result == Delivered
  debug "push ", size
  discard fetchSub(mail[].writers, 1, order = mo)
  if result == Delivered:
    discard fetchAdd(mail[].writes, 1, order = mo)
    let prior = fetchAdd(mail[].size, 1, order = mo)
    if disable(mail[].state, Empty):
      checkWake wakeMask(mail[].state, <<!Empty)
    if prior >= capacity-1:
      discard mail[].markFull()
  when insideoutSafeMode:
    debug "release"
    release mail[].lock

proc trySend*[T](mail: Mailbox[T]; item: var T): MailFlag =
  ## non-blocking attempt to push an item into the mailbox
  assert not mail.isNil
  when not defined(danger):
    if unlikely item.isNil:
      raise ValueError.newException "attempt to send nil"
  let state = get mail[].state
  if state && <<Paused:
    Paused
  elif state && <<!Writable:
    Unwritable
  elif state && <<!Readable and mail.len >= mail.capacity:
    Unwritable                # full and unreadable; go away
  elif state && <<Full and mail.len >= mail.capacity:
    Full
  else:
    mail.performPush(item)

proc push[T](mail: Mailbox[T]; item: var T): MailFlag =
  ## blocking push of an item
  assert not mail.isNil
  while true:
    let state = get mail[].state
    result = mail.trySend(item)
    case result
    of Delivered, Unwritable, Interrupt:
      break
    of Full:
      discard mail.performWait(state, <<!{Writable, Readable, Full})
    of Paused:
      discard mail.performWait(state, <<!{Writable, Readable, Paused})
    else:
      discard

when insideoutSafeMode:
  proc unboundedPop[T](mail: var MailboxObj[T]; item: var T): MailFlag =
    ## pop an item without regard to bounds
    withRLock mail.lock:
      if mail.list.head.isNil:
        result = Empty  # for parity with loony
      elif mail.list.head.next == mail.list.head:  # last item
        reset mail.list.head.next
        item = move mail.list.head.value
        reset mail.list
        result = Received
      else:
        var node = move mail.list.head
        mail.list.head = node.next
        if mail.list.tail.next == node:
          mail.list.tail.next = mail.list.head
        item = move node.value
        result = Received
else:
  proc unboundedPop[T](mail: var MailboxObj[T]; item: var T): MailFlag =
    ## pop an item without regard to bounds
    item = mail.queue.unsafePop()
    #item = mail.queue.pop()
    if item.isNil:
      result = Empty
    else:
      result = Received

proc performPop[T](mail: Mailbox[T]; item: var T): MailFlag =
  ## safely pop an item from the mailbox; returns Received
  let capacity = mail.capacity
  if capacity <= 0: return Empty  # no room at the inn
  let size = mail.len
  if size <= 0: return Empty
  when insideoutSafeMode:
    debug "acquire"
    acquire mail[].lock
    let mo = moSequentiallyConsistent
  else:
    let mo = moRelaxed
  discard fetchAdd(mail[].readers, 1, order = mo)
  result = unboundedPop(mail[], item)
  #assert result == Received
  debug "pop ", size, " ", result
  discard fetchSub(mail[].readers, 1, order = mo)
  if result == Received:
    when item isnot Continuation:
      if item.isNil:
        debug "remove nil"
      else:
        debug "remove ", item[]
    discard fetchAdd(mail[].reads, 1, order = mo)
    let prior = fetchSub(mail[].size, 1, order = mo)
    if disable(mail[].state, Full):
      checkWake wakeMask(mail[].state, <<!Full)
    if prior <= 1:
      discard mail[].markEmpty()
  when insideoutSafeMode:
    debug "release"
    release mail[].lock

proc tryRecv*[T](mail: Mailbox[T]; item: var T): MailFlag =
  ## non-blocking attempt to pop an item from the mailbox
  assert not mail.isNil
  let state = get mail[].state
  if state && <<Paused:
    Paused
  elif state && <<!Readable:
    Unreadable
  elif state && <<!Writable and mail.len == 0:
    Unreadable                # empty and unwritable; go away
  elif state && <<Empty and mail.len == 0:
    Empty
  else:
    mail.performPop(item)

proc pop[T](mail: Mailbox[T]; item: var T): MailFlag =
  ## blocking pop of an item
  assert not mail.isNil
  while true:
    let state = get mail[].state
    result = mail.tryRecv(item)
    case result
    of Unreadable, Received, Interrupt:
      break
    of Paused:
      discard mail.performWait(state, <<!{Readable, Writable, Paused})
    of Empty:
      discard mail.performWait(state, <<!{Readable, Writable, Empty})
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
  when T is void: raise Defect.newException "void mailboxen cannot recv()"
  while true:
    case pop(mail, result)
    of Received:
      break
    of Unreadable:
      raise ValueError.newException "unreadable mailbox"
    of Interrupt:
      raise IOError.newException "interrupted"
    else:
      discard

proc send*[T](mail: Mailbox[T]; item: sink T) =
  ## blocking push of an item into the mailbox
  assert not mail.isNil
  when T is void: raise Defect.newException "void mailboxen cannot send()"
  assert not item.isNil
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

proc state*[T](mail: Mailbox[T]): uint32 {.deprecated.} =
  assert not mail.isNil
  get mail[].state
