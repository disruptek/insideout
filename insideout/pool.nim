import std/lists

import pkg/cps

import insideout/runtime
import insideout/mailboxes

type
  PoolNode[A, B] = SinglyLinkedNode[Runtime[A, B]]
  Pool*[A, B] = object  ## a collection of runtimes
    list: SinglyLinkedList[Runtime[A, B]]
  Factory[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

proc isEmpty*(pool: var Pool): bool {.inline.} =
  pool.list.head.isNil

proc drain*[A, B](pool: var Pool[A, B]) =
  ## remove a runtime from the pool;
  ## has no effect if the pool is empty
  if not pool.isEmpty:
    #echo "-- remove node ", cast[uint](pool.list.head), " in thread ", getThreadId()
    #echo "-- remove value ", cast[uint](address pool.list.head.value), " in thread ", getThreadId()
    if not pool.list.remove(pool.list.head):
      raise ValueError.newException "remove race"

iterator mitems*[A, B](pool: var Pool[A, B]): var Runtime[A, B] =
  ## work around sigmatch
  for item in pool.list.mitems:
    yield item

proc quit*(pool: var Pool) =
  ## initiate quits for all the runtimes
  for item in pool.mitems:
    if item.ran:
      quit item

proc shutdown*(pool: var Pool) =
  ## shut down all runtimes in the pool; this operation is
  ## performed automatically when the pool leaves scope
  quit pool

  # remove runtimes as they terminate
  while not pool.isEmpty:
    drain pool

proc `=destroy`*[A, B](dest: var Pool[A, B]) =
  shutdown dest

proc `=copy`*[A, B](dest: var Pool[A, B]; src: Pool[A, B]) =
  `=destroy`(dest)
  dest.list = src.list

proc fill*[A, B](pool: var Pool[A, B]): var Runtime[A, B] =
  ## add a runtime to the pool
  var node: SinglyLinkedNode[Runtime[A, B]]
  new node
  #echo "++ add node ", cast[uint](node), " in thread ", getThreadId()
  new node.value
  #echo "++ add value ", cast[uint](address node.value), " in thread ", getThreadId()
  pool.list.prepend node
  result = node.value

proc spawn*[A, B](pool: var Pool[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]): var Runtime[A, B] =
  result = fill pool
  result.spawn(factory, mailbox)

proc spawn*[A, B](pool: var Pool[A, B]; factory: Factory[A, B]): Mailbox[B] =
  (fill pool).spawn(factory)

proc newPool*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]; initialSize: Positive = 1): Pool[A, B] =
  var n = int initialSize  # allow it to reach zero
  while n > 0:
    discard result.spawn(factory, mailbox)
    dec n

# FIXME: temp-to-perm
type
  ContinuationPool*[T] = Pool[Continuation, T]

proc count*(pool: Pool): int =
  ## count the number of runtimes in the pool
  var head {.cursor.} = pool.list.head
  while not head.isNil:
    inc result
    head = head.next
