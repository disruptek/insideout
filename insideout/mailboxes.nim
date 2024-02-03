import std/atomics
import std/hashes
import std/macros
import std/strutils

import pkg/loony

import insideout/atomic/refs
export refs

import insideout/atomic/flags
import insideout/ward
export WardFlag, Received, Delivered, Unreadable, Unwritable

type
  MailboxObj[T] = object
    ward: Ward[T]
  Mailbox*[T] = AtomicRef[MailboxObj[T]]

proc `=copy`*[T](dest: var MailboxObj[T]; src: MailboxObj[T]) {.error.}

proc `=destroy`[T](box: var MailboxObj[T]) =
  mixin `=destroy`
  clear box.ward             # best-effort free of items in the queue
  `=destroy`(box.ward)       # destroy the ward

proc hash*(mail: var Mailbox): Hash =
  ## whatfer inclusion in a table, etc.
  mixin address
  hash cast[int](address mail)

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

proc newMailbox*[T](): Mailbox[T] =
  ## create a new mailbox limited only by available memory
  new result
  when T is void:
    initWard(result[].ward)
  else:
    initWard(result[].ward, newLoonyQueue[T]())

proc newMailbox*[T](initialSize: Positive): Mailbox[T] =
  ## create a new mailbox which can hold `initialSize` items
  new result
  when T is void:
    {.warning: "void mailboxen are unbounded".}
    initWard(result[].ward)
  else:
    initWard(result[].ward, newLoonyQueue[T](), initialSize)

proc isEmpty*[T](mail: Mailbox[T]): bool =
  ## true if the mailbox is empty
  assert not mail.isNil
  mail[].ward.isEmpty

proc isFull*[T](mail: Mailbox[T]): bool =
  ## true if the mailbox is full
  assert not mail.isNil
  mail[].ward.isFull

# FIXME: send/recv either lose block or gain wait/timeout

proc recv*[T](mail: Mailbox[T]): T =
  ## blocking pop of an item from the mailbox
  assert not mail.isNil
  while true:
    case pop(mail[].ward, result)
    of Received:
      break
    of Unreadable:
      raise ValueError.newException "unreadable mailbox"
    of Interrupt:
      raise IOError.newException "interrupted"
    else:
      discard

proc tryRecv*[T](mail: Mailbox[T]; message: var T): WardFlag =
  ## non-blocking attempt to pop an item from the mailbox;
  ## true if it worked
  assert not mail.isNil
  let state = mail[].ward.state
  if state && <<!Readable:
    Readable
  elif state && <<Paused:
    Paused
  elif state && <<Empty:
    Empty
  else:
    tryPop(mail[].ward, message)

proc send*[T](mail: Mailbox[T]; item: sink T) =
  ## blocking push of an item into the mailbox
  assert not mail.isNil
  when not defined(danger):
    if unlikely item.isNil:
      raise ValueError.newException "nil message"
  while true:
    case push(mail[].ward, item)
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
  let state = mail[].ward.state
  if state && <<!Writable:
    Writable
  elif state && <<Paused:
    Paused
  elif state && <<Full:
    Full
  else:
    tryPush(mail[].ward, item)

# XXX: naming is hard

proc waitForPushable*[T](mail: Mailbox[T]): bool =
  assert not mail.isNil
  waitForPushable[T] mail[].ward

proc waitForPoppable*[T](mail: Mailbox[T]): bool =
  assert not mail.isNil
  waitForPoppable[T] mail[].ward

proc disablePush*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  closeWrite mail[].ward

proc disablePop*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  closeRead mail[].ward

proc pause*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  pause mail[].ward

proc resume*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  resume mail[].ward

proc waitForEmpty*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  waitForEmpty mail[].ward

proc waitForFull*[T](mail: Mailbox[T]) =
  assert not mail.isNil
  waitForFull mail[].ward
