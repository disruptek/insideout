import std/atomics
import std/deques
import std/hashes
import std/locks
import std/strutils

import insideout/semaphores
import insideout/atomicrefs
export atomicrefs

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
  deinitLock box.lock
  when T is not void:
    `=destroy`(box.deck)
  `=destroy`(box.write)
  `=destroy`(box.read)

proc hash*(mail: var Mailbox): Hash =
  ## whatfer inclusion in a table, etc.
  hash(cast[int](mail[]))

const
  MissingMailbox* = default(Mailbox[void])  ##
  ## a mailbox equal to all other uninitialized mailboxes

proc `==`*[A, B](a: Mailbox[A]; b: Mailbox[B]): bool =
  ## two mailboxes are identical if they have the same hash
  hash(a) == hash(b)

proc `$`*(mail: Mailbox): string =
  if mail.isInitialized:
    result = "<box:"
    result.add:
      hash(mail).int.toHex(6)
    result.add: "#"
    result.add: $mail.owners
    result.add ">"
  else:
    result.add "<box:nil>"

proc newMailbox*[T](initialSize: Positive = defaultInitialSize): Mailbox[T] =
  ## create a new mailbox which can hold `initialSize` items
  new result
  when T isnot void:
    result[].deck = initDeque[T](initialSize)
  initLock result[].lock
  initSemaphore(result[].write, initialSize)
  initSemaphore(result[].read, 0)

proc assertInitialized*(mail: Mailbox) =
  ## raise a ValueError if the mailbox is not initialized
  if unlikely mail.isNil:
    raise ValueError.newException "mailbox uninitialized"

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
  result =
    trySemaphore mail[].read:
      withLock mail[].lock:
        message = popFirst mail[].deck
  if result:
    signal mail[].write

proc send*[T](mail: Mailbox[T]; message: sink T) =
  ## push an item into the mailbox
  assertInitialized mail
  wait mail[].write
  withLock mail[].lock:
    mail[].deck.addLast:
      move message
  signal mail[].read

proc trySend*[T](mail: Mailbox[T]; message: var T): bool =
  ## try to push an item into the mailbox; true if it worked
  assertInitialized mail
  result =
    trySemaphore mail[].write:
      withLock mail[].lock:
        mail[].deck.addLast:
          move message
  if result:
    signal mail[].read

proc tryMoveMail*[T](a, b: Mailbox[T]) =
  ## try to move items from mailbox `a` into mailbox `b`
  var item: T
  block complete:
    while a.tryRecv(item):
      if not b.trySend(item):
        break complete

proc len*[T](mail: Mailbox[T]): int =
  ## length of the mailbox
  assertInitialized mail
  withLock mail[].lock:
    result = len mail[].deck
