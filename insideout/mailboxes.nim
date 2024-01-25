# TODO:
# impl a variety of mailboxen over mqueues
# restore mailboxen built on locks
# impl signalfd handling for thread/process signals
# impl eventfd for handling thread state changes
import std/hashes
import std/strutils
import std/atomics

import pkg/loony

import insideout/atomic/refs
export refs

import insideout/ward
export WardFlag

type
  BoundedFifoObj[T] = object
    when T isnot void:
      ward: BoundedWard[T]
  BoundedFifo*[T] = AtomicRef[BoundedFifoObj[T]]
  UnboundedFifoObj[T] = object
    when T isnot void:
      ward: UnboundedWard[T]
  UnboundedFifo*[T] = AtomicRef[UnboundedFifoObj[T]]

  MailboxObj[T] = BoundedFifoObj[T] or UnboundedFifoObj[T]
  Mailbox*[T] = BoundedFifo[T] or UnboundedFifo[T]

proc `=copy`*[T](dest: var BoundedFifoObj[T]; src: BoundedFifoObj[T]) {.error.}
proc `=copy`*[T](dest: var UnboundedFifoObj[T]; src: UnboundedFifoObj[T]) {.error.}

proc `=destroy`[T](box: var BoundedFifoObj[T]) =
  mixin `=destroy`
  when T isnot void:
    clear box.ward             # best-effort free of items in the queue
    `=destroy`(box.ward)       # destroy the ward

proc `=destroy`[T](box: var UnboundedFifoObj[T]) =
  mixin `=destroy`
  when T isnot void:
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

when defined(danger):
  template assertInitialized*(mail: Mailbox): untyped = discard
else:
  proc assertInitialized*(mail: Mailbox) =
    ## raise a Defect if the mailbox is not initialized
    if unlikely mail.isNil:
      raise AssertionDefect.newException "mailbox uninitialized"

proc newUnboundedFifo*[T](): UnboundedFifo[T] =
  ## create a new unbounded fifo
  new result
  when T isnot void:
    initWard(result[].ward, newLoonyQueue[T]())

proc newBoundedFifo*[T](initialSize: Positive): BoundedFifo[T] =
  ## create a new mailbox which can hold `initialSize` items
  new result
  when T isnot void:
    initWard(result[].ward, newLoonyQueue[T](), initialSize)

template newMailbox*[T](): UnboundedFifo[T] =
  ## create a new mailbox of unbounded size
  newUnboundedFifo[T]()

template newMailbox*[T](initialSize: Positive): BoundedFifo[T] =
  ## create a new mailbox with finite size
  newBoundedFifo[T](initialSize)

proc flags*[T](mail: Mailbox[T]): set[WardFlag] =
  ## return the current state of the mailbox
  assertInitialized mail
  mail[].ward.flags

# FIXME: send/recv either lose block or gain wait/timeout

proc recv*[T](mail: Mailbox[T]): T =
  ## blocking pop of an item from the mailbox
  assertInitialized mail
  while true:
    case pop(mail[].ward, result)
    of Writable:
      break
    of Readable:
      raise ValueError.newException "unreadable mailbox"
    else:
      discard

proc tryRecv*[T](mail: Mailbox[T]; message: var T): WardFlag =
  ## non-blocking attempt to pop an item from the mailbox;
  ## true if it worked
  assertInitialized mail
  let flags = mail.flags
  if Readable notin flags:
    Readable
  elif Paused in flags:
    Paused
  elif Empty in flags:
    Empty
  else:
    tryPop(mail[].ward, message)

proc send*[T](mail: Mailbox[T]; item: sink T) =
  ## blocking push of an item into the mailbox
  assertInitialized mail
  when not defined(danger):
    if unlikely item.isNil:
      raise ValueError.newException "nil message"
  while true:
    case push(mail[].ward, item)
    of Readable:
      break
    of Writable:
      raise ValueError.newException "unwritable mailbox"
    else:
      discard

proc trySend*[T](mail: Mailbox[T]; item: sink T): WardFlag =
  ## non-blocking attempt to push an item into the mailbox;
  ## true if it worked
  assertInitialized mail
  when not defined(danger):
    if unlikely item.isNil:
      raise ValueError.newException "attempt to send nil"
  let flags = mail.flags
  if Writable notin flags:
    Writable
  elif Paused in flags:
    Paused
  elif Full in flags:
    Full
  else:
    tryPush(mail[].ward, item)

# XXX: naming is hard

proc waitForPushable*[T](mail: Mailbox[T]): bool =
  assertInitialized mail
  waitForPushable[T] mail[].ward

proc waitForPoppable*[T](mail: Mailbox[T]): bool =
  assertInitialized mail
  waitForPoppable[T] mail[].ward

proc disablePush*[T](mail: Mailbox[T]) =
  assertInitialized mail
  closeWrite mail[].ward

proc disablePop*[T](mail: Mailbox[T]) =
  assertInitialized mail
  closeRead mail[].ward

proc pause*[T](mail: Mailbox[T]) =
  assertInitialized mail
  pause mail[].ward

proc resume*[T](mail: Mailbox[T]) =
  assertInitialized mail
  resume mail[].ward

proc waitForEmpty*[T](mail: Mailbox[T]) =
  assertInitialized mail
  waitForEmpty mail[].ward

proc waitForFull*[T](mail: Mailbox[T]) =
  assertInitialized mail
  waitForFull mail[].ward
