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
  MailboxObj[T] = object
    when T isnot void:
      ward: UnBoundedWard[T]
      queue: LoonyQueue[T]

  Mailbox*[T] {.requiresInit.} = AtomicRef[MailboxObj[T]]

proc `=copy`*[T](dest: var MailboxObj[T]; src: MailboxObj[T]) {.error.}

proc `=destroy`[T](box: var MailboxObj[T]) =
  mixin `=destroy`
  when T isnot void:
    if not box.queue.isNil:
      clear box.ward             # best-effort free of items in the queue
      `=destroy`(box.ward)       # destroy the ward
      `=destroy`(box.queue)      # destroy the queue

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

when defined(danger):
  template assertInitialized*(mail: Mailbox): untyped = discard
else:
  proc assertInitialized*(mail: Mailbox) =
    ## raise a Defect if the mailbox is not initialized
    if unlikely mail.isNil:
      raise AssertionDefect.newException "mailbox uninitialized"

proc newMailbox*[T](): Mailbox[T] =
  ## create a new mailbox of unbounded size
  new result
  when T isnot void:
    result[].queue = newLoonyQueue[T]()
    initWard(result[].ward, result[].queue)

proc newMailbox*[T](initialSize: Positive): Mailbox[T] =
  ## create a new mailbox which can hold `initialSize` items
  new result
  when T isnot void:
    result[].queue = newLoonyQueue[T]()
    when result[].ward is BoundedWard[T]:
      initWard(result[].ward, result[].queue, initialSize)
    else:
      initWard(result[].ward, result[].queue)

proc flags*[T](mail: Mailbox[T]): set[WardFlag] =
  ## return the current state of the mailbox
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
      raise ValueError.newException "write-only mailbox"
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
    if item.isNil:
      raise ValueError.newException "nil message"
  while true:
    case push(mail[].ward, item)
    of Readable:
      break
    of Writable:
      raise ValueError.newException "read-only mailbox"
    else:
      discard

proc trySend*[T](mail: Mailbox[T]; item: sink T): WardFlag =
  ## non-blocking attempt to push an item into the mailbox;
  ## true if it worked
  assertInitialized mail
  if item.isNil:
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
