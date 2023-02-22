import std/lists

import pkg/cps

import insideout/runtimes
import insideout/mailboxes

type
  PoolNode[A, B] {.used.} = SinglyLinkedNode[Runtime[A, B]]
  Pool*[A, B] = object  ## a collection of runtimes
    list: SinglyLinkedList[Runtime[A, B]]
  Factory[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

proc safeRemove[T](L: var SinglyLinkedList[T], n: SinglyLinkedNode[T]): bool {.discardable.} =
  ## Removes a node `n` from `L`.
  ## Returns `true` if `n` was found in `L`.
  ## Efficiency: O(n); the list is traversed until `n` is found.
  ## Attempting to remove an element not contained in the list is a no-op.
  ## Differs from stdlib's lists.remove() in that it has no special
  ## cyclic behavior which causes memory errors.  🙄
  runnableExamples:
    import std/[sequtils, enumerate, sugar]
    var a = [0, 1, 2].toSinglyLinkedList
    let n = a.head.next
    assert n.value == 1
    assert a.remove(n) == true
    assert a.toSeq == [0, 2]
    assert a.remove(n) == false
    assert a.toSeq == [0, 2]
    a.addMoved(a) # cycle: [0, 2, 0, 2, ...]
    a.remove(a.head)
    let s = collect:
      for i, ai in enumerate(a):
        if i == 4: break
        ai
    assert s == [2, 2, 2, 2]

  if n == L.head:
    L.head = n.next
    when false:
      if L.tail.next == n:
        L.tail.next = L.head # restore cycle
  else:
    var prev = L.head
    while prev.next != n and prev.next != nil:
      prev = prev.next
    if prev.next == nil:
      return false
    prev.next = n.next
    if L.tail == n:
      L.tail = prev # update tail if we removed the last node
  true

func isEmpty*(pool: var Pool): bool {.inline.} =
  pool.list.head.isNil

proc drain*[A, B](pool: var Pool[A, B]) =
  ## remove a runtime from the pool;
  ## has no effect if the pool is empty
  if not pool.isEmpty:
    if not pool.list.safeRemove(pool.list.head):
      raise ValueError.newException "remove race"

iterator mitems*[A, B](pool: var Pool[A, B]): var Runtime[A, B] =
  ## work around sigmatch
  for item in pool.list.mitems:
    yield item

proc shutdown*(pool: var Pool) =
  ## shut down all runtimes in the pool; this operation is
  ## performed automatically when the pool leaves scope

  # XXX: this gets rewritten for detached...
  for item in pool.mitems:
    when insideoutDetached:
      quit item
    else:
      item.mailbox.send nil

  # remove runtimes as they terminate
  while not pool.isEmpty:
    drain pool

proc `=destroy`*[A, B](pool: var Pool[A, B]) =
  if not pool.isEmpty:
    shutdown pool

proc `=copy`*[A, B](dest: var Pool[A, B]; src: Pool[A, B]) =
  `=destroy`(dest)
  dest.list = src.list

proc add*[A, B](pool: var Pool[A, B]; runtime: Runtime[A, B]) =
  var node: SinglyLinkedNode[Runtime[A, B]]
  new node
  node.value = runtime
  pool.list.prepend node

proc spawn*[A, B](pool: var Pool[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]): Runtime[A, B] {.discardable.} =
  result = spawn(factory, mailbox)
  pool.add result

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
