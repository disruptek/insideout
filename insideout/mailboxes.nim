import std/atomics
import std/deques
import std/hashes
import std/strutils

import pkg/nimactors/isisolated

import insideout/semaphores

type
  MailboxObj[T] = object
    deck: Deque[T]
    write: Semaphore
    read: Semaphore
    rc: Atomic[int]

  Mailbox*[T] = object
    box: ptr MailboxObj[T]

proc isInitialized*[T](mail: Mailbox[T]): bool {.inline.} =
  not mail.box.isNil

proc hash*(mail: var Mailbox): Hash =
  ## whatfer inclusion in a table, etc.
  hash(cast[int](mail.box))

const
  MissingMailbox* = default(Mailbox[void])

proc `==`*[A, B](a: Mailbox[A]; b: Mailbox[B]): bool =
  hash(a) == hash(b)

proc `$`*(mail: Mailbox): string =
  `&`"<mail:":
    if mail.isInitialized:
      hash(mail).int.toHex(6) & ">"
    else:
      "nil>"

template assertInitialized*[T](mail: Mailbox[T]): untyped =
  if unlikely (not mail.isInitialized):
    raise ValueError.newException "mailbox uninitialized"

proc owners*[T](mail: Mailbox[T]): int =
  ## returns the number of owners; this value is positive for
  ## initialized mailboxen and zero for all others
  if mail.isInitialized:
    result = load(mail.box.rc, moAcquire) + 1

proc `=destroy`*[T](mail: var Mailbox[T]) =
  # permit destroy of unassigned mailboxen
  if mail.isInitialized:
    let prior = fetchSub(mail.box.rc, 1, moAcquire)
    if prior == 0:
      deallocShared mail.box
      echo "destroy freed " & $mail & " in thread " & $getThreadId()
    else:
      echo "destroy " & $mail & "; counter now " & $(prior - 1) & " in thread " & $getThreadId()
      discard
    mail.box = nil

proc `=copy`*[T](dest: var Mailbox[T]; src: Mailbox[T]) =
  # permit copy of unassigned mailboxen
  if src.isInitialized:
    when true:
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
    let was = fetchSub(mail.box.rc, 1)
    echo "forget " & $mail & "; counter now " & $(was - 1) & " in " & $getThreadId()

proc newMailbox*[T](initialSize: int = defaultInitialSize): Mailbox[T] =
  result.box = cast[ptr MailboxObj[T]](allocShared0(sizeof MailboxObj[T]))
  result.box.deck = initDeque[T](initialSize)
  initSemaphore(result.box.write, initialSize)
  initSemaphore(result.box.read, 0)
  #echo "init " & $result & " in " & $getThreadId()

proc recv*[T](mail: Mailbox[T]): T =
  assertInitialized mail
  withSemaphore mail.box.read:
    result = popFirst mail.box.deck
  signal mail.box.write

proc send*[T](mail: Mailbox[T]; message: sink T) =
  assertInitialized mail
  assertIsolated message
  withSemaphore mail.box.write:
    mail.box.deck.addLast message
    when T is ref:
      wasMoved message
  signal mail.box.read

proc resizeBy[T](mail: Mailbox[T]; amount: int) {.used.} =
  ## adjust mailbox size for future submissions
  assertInitialized mail
  for n in 0..abs(amount):
    if amount < 0:
      dec mail.box.write
    else:
      signal mail.box.write
