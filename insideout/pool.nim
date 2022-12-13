import std/lists

import pkg/cps

import insideout/runtime
import insideout/mailboxes

type
  PoolNode[A, B] = SinglyLinkedNode[Runtime[A, B]]
  Pool*[A, B] = object  ## a collection of runtimes
    list: SinglyLinkedList[Runtime[A, B]]
  Factory[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

proc remove*[A, B](pool: var Pool[A, B]; node: PoolNode[A, B]): bool {.discardable.} =
  ## work around sigmatch
  pool.list.remove(node)

proc prepend*[A, B](pool: var Pool[A, B]; node: PoolNode[A, B]) =
  ## work around sigmatch
  pool.list.prepend(node)

proc head[A, B](pool: Pool[A, B]): PoolNode[A, B] =
  ## work around sigmatch
  pool.list.head

iterator mitems*[A, B](pool: var Pool[A, B]): var Runtime[A, B] =
  ## work around sigmatch
  for item in pool.list.mitems:
    yield item

proc quit*(pool: var Pool) =
  ## initiate quits for all the runtimes
  for item in pool.mitems:
    if item.ran:
      quit item

proc drain*(pool: var Pool) =
  ## shut down all runtimes in the pool
  quit pool

  # remove runtimes as they terminate
  while not pool.head.isNil:
    join pool.head.value
    pool.remove(pool.head)

proc `=destroy`*[A, B](dest: var Pool[A, B]) =
  drain dest

proc `=copy`*[A, B](dest: var Pool[A, B]; src: Pool[A, B]) =
  `=destroy`(dest)
  dest.list = src.list

proc fill*[A, B](pool: var Pool[A, B]): var Runtime[A, B] =
  ## add a runtime to the pool
  var node: SinglyLinkedNode[Runtime[A, B]]
  new node
  pool.list.prepend node
  result = node.value

when false:
  {.warning: "nim compiler bug".}
  proc spawn*[A, B](pool: var Pool[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]): var Runtime[A, B] =
    result = fill pool
    result.spawn(factory, mailbox)
else:
  proc spawn*[A, B](pool: var Pool[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
    (fill pool).spawn(factory, mailbox)

proc newPool*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]; initialSize: Positive = 1): Pool[A, B] =
  var n = int initialSize  # allow it to reach zero
  while n > 0:
    result.spawn(factory, mailbox)
    dec n

# FIXME: temp-to-perm
type
  ContinuationPool*[T] = Pool[Continuation, T]
  ContinuationFactory[T] = Factory[Continuation, T]

proc count*(pool: Pool): int =
  ## count the number of runtimes in the pool
  var head = pool.head
  while not head.isNil:
    inc result
    head = head.next

proc isEmpty*(pool: Pool): bool =
  pool.head.isNil
