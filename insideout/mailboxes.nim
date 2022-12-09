import std/atomics
import std/deques
import std/hashes
import std/locks
import std/strutils

import insideout/semaphores

type
  MailboxObj[T] = object
    deck: Deque[T]
    lock: Lock
    write: Semaphore
    read: Semaphore
    rc: Atomic[int]

  Mailbox*[T] = object  ## a queue for `T` values
    box: ptr MailboxObj[T]

template debug(arguments: varargs[untyped]): untyped =
  when not defined(release):
    echo arguments

proc isInitialized*(mail: Mailbox): bool {.inline.} =
  ## true if the mailbox has been initialized
  not mail.box.isNil

proc hash*(mail: var Mailbox): Hash =
  ## whatfer inclusion in a table, etc.
  hash(cast[int](mail.box))

const
  MissingMailbox* = default(Mailbox[void])  ##
  ## a mailbox equal to all other uninitialized mailboxes

proc `==`*[A, B](a: Mailbox[A]; b: Mailbox[B]): bool =
  ## two mailboxes are identical if they have the same hash
  hash(a) == hash(b)

proc owners*[T](mail: Mailbox[T]): int =
  ## returns the number of owners; this value is positive for
  ## initialized mailboxen and zero for all others
  if mail.isInitialized:
    result = load(mail.box.rc, moAcquire) + 1

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

proc assertInitialized*(mail: Mailbox) =
  ## raise a ValueError if the mailbox is not initialized
  if unlikely (not mail.isInitialized):
    raise ValueError.newException "mailbox uninitialized"

proc `=destroy`*[T](box: var MailboxObj[T]) =
  deinitLock box.lock
  `=destroy`(box.deck)
  `=destroy`(box.write)
  `=destroy`(box.read)

proc `=destroy`*[T](mail: var Mailbox[T]) =
  # permit destroy of unassigned mailboxen
  if mail.isInitialized:
    let prior = fetchSub(mail.box.rc, 1, moAcquire)
    if prior == 0:
      `=destroy`(mail.box)
      deallocShared mail.box
      debug "destroy freed " & $mail & " in thread " & $getThreadId()
    else:
      debug "destroy " & $mail & "; counter now " & $(prior - 1) & " in thread " & $getThreadId()
    mail.box = nil

proc `=copy`*[T](dest: var Mailbox[T]; src: Mailbox[T]) =
  # permit copy of unassigned mailboxen
  if src.isInitialized:
    when defined(release):
      src.box.rc += 1
    else:
      let was = fetchAdd(src.box.rc, 1)
      debug "copy ", src, "; counter now ", (1 + was), " in ", getThreadId()
  if dest.isInitialized:
    `=destroy`(dest)
  dest.box = src.box

proc len*[T](mail: Mailbox[T]): int =
  ## length of the mailbox
  assertInitialized mail
  withLock mail.box.lock:
    result = len mail.box.deck

proc forget*(mail: Mailbox) {.deprecated: "debugging tool".} =
  ## cheat mode
  if mail.isInitialized:
    when defined(release):
      mail.box.rc -= 1
    else:
      let was = fetchSub(mail.box.rc, 1)
      debug "forget ", mail, "; counter now ", (was - 1), " in ", getThreadId()

proc newMailbox*[T](initialSize: Positive = defaultInitialSize): Mailbox[T] =
  ## create a new mailbox which can hold `initialSize` items
  result.box = cast[ptr MailboxObj[T]](allocShared0(sizeof MailboxObj[T]))
  result.box.deck = initDeque[T](initialSize)
  initLock result.box.lock
  initSemaphore(result.box.write, initialSize)
  initSemaphore(result.box.read, 0)
  debug "init ", result, ", size ", initialSize, " in ", getThreadId()

proc recv*[T](mail: Mailbox[T]): T =
  ## pop an item from the mailbox
  assertInitialized mail
  wait mail.box.read
  withLock mail.box.lock:
    result = popFirst mail.box.deck
  signal mail.box.write

proc tryRecv*[T](mail: Mailbox[T]; message: var T): bool =
  ## try to pop an item from the mailbox; true if it worked
  assertInitialized mail
  result =
    trySemaphore mail.box.read:
      withLock mail.box.lock:
        message = popFirst mail.box.deck
  if result:
    signal mail.box.write

proc send*[T](mail: Mailbox[T]; message: sink T) =
  ## push an item into the mailbox
  assertInitialized mail
  wait mail.box.write
  withLock mail.box.lock:
    mail.box.deck.addLast:
      move message
  signal mail.box.read

proc trySend*[T](mail: Mailbox[T]; message: var T): bool =
  ## try to push an item into the mailbox; true if it worked
  assertInitialized mail
  result =
    trySemaphore mail.box.write:
      withLock mail.box.lock:
        mail.box.deck.addLast:
          move message
  if result:
    signal mail.box.read
