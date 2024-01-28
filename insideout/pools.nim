# TODO:
#
#
# pools should type-erase if possible
# impl variety
import std/lists

import pkg/cps

import insideout/runtimes
import insideout/mailboxes

type
  PoolNode[A, B] {.used.} = SinglyLinkedNode[Runtime[A, B]]
  PoolObj[A, B] = object  ## a collection of runtimes
    list: SinglyLinkedList[Runtime[A, B]]
  Pool*[A, B] = AtomicRef[PoolObj[A, B]]

proc `=copy`*[A, B](dest: var PoolObj[A, B]; src: PoolObj[A, B]) {.error.}

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

func isEmpty[A, B](pool: var PoolObj[A, B]): bool =
  pool.list.head.isNil

func isEmpty*[A, B](pool: var Pool): bool =
  assert not pool.isNil
  pool[].isEmpty

proc drain[A, B](pool: var PoolObj[A, B]) =
  if not pool.isEmpty:
    if not pool.list.safeRemove(pool.list.head):
      raise ValueError.newException "remove race"

proc drain*[A, B](pool: var Pool[A, B]) =
  ## remove a runtime from the pool;
  ## has no effect if the pool is empty
  assert not pool.isNil
  drain pool[]

iterator mitems*[A, B](pool: var Pool[A, B]): var Runtime[A, B] =
  ## work around sigmatch
  assert not pool.isNil
  for item in pool[].list.mitems:
    yield item

proc shutdown[A, B](pool: var PoolObj[A, B]) =
  for item in pool.list.mitems:
    stop item

  # remove runtimes as they terminate
  while not pool.isEmpty:
    drain pool

proc shutdown*[A, B](pool: var Pool[A, B]) =
  ## shut down all runtimes in the pool; this operation is
  ## performed automatically when the pool leaves scope
  assert not pool.isNil
  shutdown pool[]

proc `=destroy`*[A, B](pool: var PoolObj[A, B]) =
  if not pool.list.head.isNil:
    shutdown pool

proc add*[A, B](pool: var Pool[A, B]; runtime: Runtime[A, B]) =
  assert not pool.isNil
  var node: SinglyLinkedNode[Runtime[A, B]]
  new node
  node.value = runtime
  pool[].list.prepend node

proc spawn*[A, B](pool: var Pool[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]): Runtime[A, B] {.discardable.} =
  assert not pool.isNil
  result = spawn(factory, mailbox)
  pool.add result

proc newPool*[A, B](factory: Factory[A, B]): Pool[A, B] =
  new result

proc newPool*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]; initialSize: Natural = 0): Pool[A, B] =
  result = newPool(factory)
  var n = initialSize
  while n > 0:
    discard result.spawn(factory, mailbox)
    dec n

# FIXME: temp-to-perm
type
  ContinuationPool*[T] = Pool[Continuation, T]

proc count*[A, B](pool: Pool[A, B]): int =
  ## count the number of runtimes in the pool
  assert not pool.isNil
  var head {.cursor.} = pool[].list.head
  while not head.isNil:
    inc result
    head = head.next
