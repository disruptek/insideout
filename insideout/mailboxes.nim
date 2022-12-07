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

proc `$`*(mail: Mailbox): string =
  `&`"<mail:":
    if mail.isInitialized:
      hash(mail).int.toHex(6) & ">"
    else:
      "nil>"

proc assertInitialized*(mail: Mailbox) =
  ## raise a ValueError if the mailbox is not initialized
  if unlikely (not mail.isInitialized):
    raise ValueError.newException "mailbox uninitialized"

proc owners*[T](mail: Mailbox[T]): int =
  ## returns the number of owners; this value is positive for
  ## initialized mailboxen and zero for all others
  if mail.isInitialized:
    result = load(mail.box.rc, moAcquire) + 1

proc `=destroy`*[T](box: var MailboxObj[T]) =
  deinitLock box.lock
  `=destroy`(box.write)
  `=destroy`(box.read)

proc `=destroy`*[T](mail: var Mailbox[T]) =
  # permit destroy of unassigned mailboxen
  if mail.isInitialized:
    let prior = fetchSub(mail.box.rc, 1, moAcquire)
    if prior == 0:
      deallocShared mail.box
      when not defined(release):
        echo "destroy freed " & $mail & " in thread " & $getThreadId()
    else:
      when not defined(release):
        echo "destroy " & $mail & "; counter now " & $(prior - 1) & " in thread " & $getThreadId()
    mail.box = nil

proc `=copy`*[T](dest: var Mailbox[T]; src: Mailbox[T]) =
  # permit copy of unassigned mailboxen
  if src.isInitialized:
    when defined(release):
      src.box.rc += 1
    else:
      let was = fetchAdd(src.box.rc, 1)
      echo "copy " & $src & "; counter now " & $(1 + was) & " in " & $getThreadId()
  if dest.isInitialized:
    `=destroy`(dest)
  dest.box = src.box

proc forget*(mail: Mailbox) {.deprecated: "debugging tool".} =
  ## cheat mode
  if mail.isInitialized:
    when defined(release):
      mail.box.rc -= 1
    else:
      let was = fetchSub(mail.box.rc, 1)
      echo "forget " & $mail & "; counter now " & $(was - 1) & " in " & $getThreadId()

proc newMailbox*[T](initialSize: int = defaultInitialSize): Mailbox[T] =
  ## create a new mailbox which can hold `initialSize` items
  result.box = cast[ptr MailboxObj[T]](allocShared0(sizeof MailboxObj[T]))
  result.box.deck = initDeque[T](initialSize)
  initLock result.box.lock
  initSemaphore(result.box.write, initialSize)
  initSemaphore(result.box.read, 0)
  when not defined(release):
    echo "init " & $result & ", size " & $initialSize & " in " & $getThreadId()

proc recv*[T](mail: Mailbox[T]): T =
  ## pop an item from the mailbox
  assertInitialized mail
  wait mail.box.read
  withLock mail.box.lock:
    result = popFirst mail.box.deck
  signal mail.box.write

proc send*[T](mail: Mailbox[T]; message: sink T) =
  ## push an item into the mailbox
  assertInitialized mail
  wait mail.box.write
  withLock mail.box.lock:
    mail.box.deck.addLast message
    when T is ref:
      wasMoved message
  signal mail.box.read
