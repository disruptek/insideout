import std/lists

import pkg/cps

import insideout/runtime
import insideout/mailboxes

type
  PoolNode[A, B] = SinglyLinkedNode[Runtime[A, B]]
  Pool*[A, B] = distinct SinglyLinkedList[Runtime[A, B]]  ## a collection of runtimes
  Factory[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

proc remove*[A, B](pool: var Pool[A, B]; node: PoolNode[A, B]): bool {.discardable.} =
  ## work around sigmatch
  SinglyLinkedList[Runtime[A, B]](pool).remove(node)

proc prepend*[A, B](pool: var Pool[A, B]; node: PoolNode[A, B]) =
  ## work around sigmatch
  SinglyLinkedList[Runtime[A, B]](pool).prepend(node)

proc head*[A, B](pool: Pool[A, B]): PoolNode[A, B] =
  ## work around sigmatch
  SinglyLinkedList[Runtime[A, B]](pool).head

iterator mitems*[A, B](pool: var Pool[A, B]): var Runtime[A, B] =
  ## work around sigmatch
  for item in SinglyLinkedList[Runtime[A, B]](pool).mitems:
    yield item

proc drain*(pool: var Pool) =
  ## shut down all runtimes in the pool
  # initiate quits for all the runtimes
  for item in pool.mitems:
    if item.ran:
      quit item

  # remove runtimes as they terminate
  while not pool.head.isNil:
    join pool.head.value
    pool.remove(pool.head)

proc fill*[A, B](pool: var Pool[A, B]): var Runtime[A, B] =
  ## add a runtime to the pool
  var node: SinglyLinkedNode[Runtime[A, B]]
  new node
  pool.prepend node
  result = node.value

proc spawn*[A, B](pool: var Pool[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
  pool.fill.spawn(factory, mailbox)

proc newPool*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]; initialSize: Positive = 1): Pool[A, B] =
  var n = int initialSize  # allow it to reach zero
  while n > 0:
    result.spawn(factory, mailbox)
    dec n

# FIXME: temp-to-perm
type
  ContinuationPool*[T] = SinglyLinkedList[ContinuationRuntime[T]]
  ContinuationFactory[T] = Factory[Continuation, T]

template spawn*[T](pool: var ContinuationPool[T]; factory: ContinuationFactory[T]; mailbox: Mailbox[T]) =
  pool.spawn(factory, mailbox)

template newPool*[T](factory: ContinuationFactory[T]; mailbox: Mailbox[T]; initialSize: Positive = 1): ContinuationPool[T] =
  newPool(factory, mailbox)

proc count*(pool: Pool): int =
  ## count the number of runtimes in the pool
  var head = pool.head
  while not head.isNil:
    inc result
    head = head.next

proc isEmpty*(pool: Pool): bool =
  pool.head.isNil
