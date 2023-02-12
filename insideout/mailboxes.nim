import std/deques
import std/hashes
import std/locks
import std/strutils

import insideout/semaphores
import insideout/atomic/refs
export refs

type
  MailboxObj[T] = object
    when T isnot void:
      deck: Deque[T]
    lock: Lock
    write: Semaphore
    read: Semaphore

  Mailbox*[T] = AtomicRef[MailboxObj[T]]

proc `=copy`*[T](dest: var MailboxObj[T]; src: MailboxObj[T]) {.error.}

proc `=destroy`[T](box: var MailboxObj[T]) =
  mixin `=destroy`
  deinitLock box.lock
  when T isnot void:
    `=destroy`(box.deck)
  `=destroy`(box.write)
  `=destroy`(box.read)

proc hash*(mail: var Mailbox): Hash =
  ## whatfer inclusion in a table, etc.
  mixin address
  hash cast[int](address mail)

const
  MissingMailbox* = default(Mailbox[void])  ##
  ## a mailbox equal to all other uninitialized mailboxes

proc `==`*[A, B](a: Mailbox[A]; b: Mailbox[B]): bool =
  ## two mailboxes are identical if they have the same hash
  mixin hash
  hash(a) == hash(b)

proc `$`*(mail: Mailbox): string =
  if mail.isNil:
    result = "<box:nil>"
  else:
    result = "<box:"
    result.add:
      hash(mail).int.toHex(6)
    result.add: "#"
    result.add: $mail.owners
    result.add ">"

proc assertInitialized*(mail: Mailbox) =
  ## raise a ValueError if the mailbox is not initialized
  if unlikely mail.isNil:
    raise ValueError.newException "mailbox uninitialized"

proc len*[T](mail: Mailbox[T]): int =
  ## length of the mailbox
  assertInitialized mail
  withLock mail[].lock:
    result = len mail[].deck

proc newMailbox*[T](initialSize: Positive = defaultInitialSize): Mailbox[T] =
  ## create a new mailbox which can hold `initialSize` items
  new result
  when T isnot void:
    result[].deck = initDeque[T](initialSize)
  initLock result[].lock
  initSemaphore(result[].write, initialSize)
  initSemaphore(result[].read, 0)

proc recv*[T](mail: Mailbox[T]): T =
  ## pop an item from the mailbox
  assertInitialized mail
  wait mail[].read
  withLock mail[].lock:
    result = popFirst mail[].deck
  signal mail[].write

proc tryRecv*[T](mail: Mailbox[T]; message: var T): bool =
  ## try to pop an item from the mailbox; true if it worked
  assertInitialized mail
  result = tryWait mail[].read
  if result:
    withLock mail[].lock:
      message = popFirst mail[].deck
    signal mail[].write

proc send*[T](mail: Mailbox[T]; message: sink T) =
  ## push an item into the mailbox
  assertInitialized mail
  wait mail[].write
  withLock mail[].lock:
    addLast mail[].deck:
      move message
  signal mail[].read

proc trySend*[T](mail: Mailbox[T]; message: var T): bool =
  ## try to push an item into the mailbox; true if it worked
  assertInitialized mail
  result = tryWait mail[].write
  if result:
    withLock mail[].lock:
      addLast mail[].deck:
        move message
    signal mail[].read

proc tryMoveMail*[T](a, b: Mailbox[T]) =
  ## try to move items from mailbox `a` into mailbox `b`
  var item: T
  block complete:
    while a.tryRecv(item):
      if not b.trySend(item):
        break complete
