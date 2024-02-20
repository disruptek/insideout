import std/atomics
import std/hashes
import std/os
import std/posix
import std/sets
import std/strformat
import std/strutils

import pkg/cps
import pkg/loony
from pkg/balls import checkpoint

import insideout/futexes
import insideout/atomic/flags
import insideout/atomic/refs
export refs

const insideoutSafeMode* {.booldefine.} = true

when insideoutSafeMode:
  import std/rlocks
  type
    ListNode[T] {.byref.} = ref object
      value: T
      next: ListNode[T]
    List[T] {.byref.} = object
      head: ListNode[T]
      tail: ListNode[T]
    MailboxObj[T: ref or ptr or void] {.byref.} = object
      when T isnot void:
        lock: RLock
        list: List[T]
        size: Atomic[uint32]
        capacity: Atomic[uint32]
      state: AtomicFlags32
      reads: Atomic[uint64]
      writes: Atomic[uint64]
      readers: Atomic[uint32]
      writers: Atomic[uint32]
    Mailbox*[T] = AtomicRef[MailboxObj[T]]
else:
  type
    # we need a .byref. while the object is so small
    MailboxObj[T: ref or ptr or void] {.byref.} = object
      when T isnot void:
        queue: LoonyQueue[T]
        size: Atomic[uint32]
        capacity: Atomic[uint32]
      state: AtomicFlags32
      reads: Atomic[uint32]
      writes: Atomic[uint32]
      readers: Atomic[uint32]
      writers: Atomic[uint32]
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
  if 0 != (flags and <<Bounded):
    put(mail.state, boundedFlags)
  else:
    put(mail.state, unboundedFlags)
  # wake all waiters on the flags in order to free any
  # queued waiters in kernel space
  checkWake wake(mail.state)
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
  store(mail.capacity, 0, order = moSequentiallyConsistent)
  store(mail.size, 0, order = moSequentiallyConsistent)
  store(mail.reads, 0, order = moSequentiallyConsistent)
  store(mail.writes, 0, order = moSequentiallyConsistent)
  # this should ruin it sufficiently
  store(mail.readers, 0, order = moSequentiallyConsistent)
  store(mail.writers, 0, order = moSequentiallyConsistent)

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
  when insideoutSafeMode:
    initRLock result[].lock
  when T isnot void:
    when insideoutSafeMode:
      reset result[].list
    else:
      if not result[].queue.isNil:
        while not result[].queue.pop.isNil:
          discard
        reset result[].queue
      result[].queue = newLoonyQueue[T]()
  store(result[].capacity, capacity, order = moSequentiallyConsistent)
  store(result[].size, 0, order = moSequentiallyConsistent)
  store(result[].reads, 0, order = moSequentiallyConsistent)
  store(result[].writes, 0, order = moSequentiallyConsistent)
  # a valid bitmask for futex use
  store(result[].readers, 1, order = moSequentiallyConsistent)
  store(result[].writers, 1, order = moSequentiallyConsistent)
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

proc performWait[T](mail: Mailbox[T]; has: uint32; wants: uint32): bool {.discardable.} =
  ## true if we had to wait; false otherwise
  result = 0 == (has and wants)
  if result:
    when insideoutSafeMode:
      checkWait waitMask(mail[].state, has, wants, 0.1)
    else:
      checkWait waitMask(mail[].state, has, wants)

proc isEmpty*[T](mail: Mailbox[T]): bool =
  assert not mail.isNil
  when T is void:
    true
  else:
    when not insideoutSafeMode:
      assert not mail[].queue.isNil
    let state = get mail[].state
    result = state && <<Empty

proc isFull*[T](mail: Mailbox[T]): bool =
  assert not mail.isNil
  when T is void:
    true
  else:
    when not insideoutSafeMode:
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
    when false:
      if mail.len == mail.capacity:
        # NOTE: short-circuit when the mailbox is full and unreadable
        result = state && <<Readable
        if result:
          discard mail.performWait(state, <<!{Writable, Readable, Full})
      else:
        discard disable(mail[].state, Full)
        checkWake wakeMask(mail[].state, <<!Full)
        result = true
    else:
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
    echo "not readable"
    result = false
  elif state && <<Paused:
    echo "paused"
    result = true
    discard mail.performWait(state, <<!{Readable, Paused})
  elif state && <<Empty:
    echo "empty"
    when false:
      if mail.len == 0:
        # NOTE: short-circuit when the mailbox is empty and unwritable
        result = state && <<Writable
        if result:
          discard mail.performWait(state, <<!{Writable, Readable, Empty})
      else:
        discard disable(mail[].state, Empty)
        checkWake wakeMask(mail[].state, <<!Empty)
        result = true
    else:
      # NOTE: short-circuit when the mailbox is empty and unwritable
      result = state && <<Writable
      if result:
        discard mail.performWait(state, <<!{Writable, Readable, Empty})
  else:
    echo "not empty ", mail.len
    result = true

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
    #if woke:
    checkWake wakeMask(mail.state, <<Empty + <<!Readable)
  else:
    result = Empty
    discard enable(mail.state, Empty)
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
    #if woke:
    checkWake wakeMask(mail.state, <<Full + <<!Writable)
  else:
    result = Full
    discard enable(mail.state, Full)
    checkWake wakeMask(mail.state, <<Full)

when insideoutSafeMode:
  proc unboundedPush[T](mail: var MailboxObj[T]; item: sink T): MailFlag =
    withRLock mail.lock:
      when not defined(danger):
        when item isnot Continuation:
          echo getThreadId(), " add item ", item[]
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
  proc unboundedPush[T](mail: var MailboxObj[T]; item: sink T): MailFlag =
    ## push an item without regard to bounds
    mail.queue.unsafePush(move item)
    #mail.queue.push(move item)
    result = Delivered

proc performPush[T](mail: Mailbox[T]; item: var T): MailFlag =
  ## safely push an item onto the mailbox; returns Delivered
  ## if successful, else Full or Interrupt
  when T is void: return Full
  let capacity = mail.capacity
  if capacity <= 0: return Full  # no room at the inn
  let size = mail.len
  if size >= capacity: return Full
  when insideoutSafeMode:
    when not defined(danger):
      echo getThreadId(), " acquire"
    acquire mail[].lock
    let mo = moSequentiallyConsistent
  else:
    let mo = moRelaxed
  discard fetchAdd(mail[].writers, 1, order = mo)
  result = unboundedPush(mail[], item)
  assert result == Delivered
  when not defined(danger):
    echo getThreadId(), " push ", size
  discard fetchSub(mail[].writers, 1, order = mo)
  if result == Delivered:
    discard fetchAdd(mail[].writes, 1, order = mo)
    let prior = fetchAdd(mail[].size, 1, order = mo)
    if disable(mail[].state, Empty):
      checkWake wakeMask(mail[].state, <<!Empty)
    if prior >= capacity-1:
      discard mail[].markFull()
  when insideoutSafeMode:
    when not defined(danger):
      echo getThreadId(), " release"
    release mail[].lock
  # FIXME
  #checkWake wake(mail[].state)

proc trySend*[T](mail: Mailbox[T]; item: var T): MailFlag =
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
      discard mail.performWait(state, <<!{Writable, Full})
    of Paused:
      discard mail.performWait(state, <<!{Writable, Paused})
    else:
      discard

when insideoutSafeMode:
  proc unboundedPop[T](mail: var MailboxObj[T]; item: var T): MailFlag =
    ## pop an item without regard to bounds
    withRLock mail.lock:
      if mail.list.head.isNil:
        when not defined(danger):
          echo getThreadId(), " remove (empty)"
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
    if result == Received:
      when not defined(danger):
        when item isnot Continuation:
          if item.isNil:
            echo getThreadId(), " remove nil"
          else:
            echo getThreadId(), " remove ", item[]
      discard fetchAdd(mail.reads, 1, order = moRelaxed)
else:
  proc unboundedPop[T](mail: var MailboxObj[T]; item: var T): MailFlag =
    ## pop an item without regard to bounds
    #item = mail.queue.unsafePop()
    item = mail.queue.pop()
    if item.isNil:
      result = Empty
    else:
      result = Received
      discard fetchAdd(mail.reads, 1, order = moRelaxed)

proc performPop[T](mail: Mailbox[T]; item: var T): MailFlag =
  ## safely pop an item from the mailbox; returns Received
  when T is void: return Empty
  let capacity = mail.capacity
  if capacity <= 0: return Empty  # no room at the inn
  let size = mail.len
  if size <= 0: return Empty
  when insideoutSafeMode:
    when not defined(danger):
      echo getThreadId(), " acquire"
    acquire mail[].lock
    let mo = moSequentiallyConsistent
  else:
    let mo = moRelaxed
  discard fetchAdd(mail[].readers, 1, order = mo)
  result = unboundedPop(mail[], item)
  assert result == Received
  when not defined(danger):
    echo getThreadId(), " pop ", size
  discard fetchSub(mail[].readers, 1, order = mo)
  if result == Received:
    when not defined(danger):
      when item isnot Continuation:
        if item.isNil:
          echo getThreadId(), " remove nil"
        else:
          echo getThreadId(), " remove ", item[]
    discard fetchAdd(mail[].reads, 1, order = mo)
    let prior = fetchSub(mail[].size, 1, order = mo)
    if disable(mail[].state, Full):
      checkWake wakeMask(mail[].state, <<!Full)
    if prior <= 1:
      discard mail[].markEmpty()
  when insideoutSafeMode:
    when not defined(danger):
      echo getThreadId(), " release"
    release mail[].lock
  # FIXME
  #checkWake wake(mail[].state)

proc tryRecv*[T](mail: Mailbox[T]; item: var T): MailFlag =
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
      discard mail.performWait(state, <<!{Readable, Paused})
    of Empty:
      discard mail.performWait(state, <<!{Readable, Empty})
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
