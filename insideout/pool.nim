import std/lists

import pkg/cps

import insideout/runtime

type
  PoolNode[A, B] = SinglyLinkedNode[Runtime[A, B]]
  Pool*[A, B] = SinglyLinkedList[Runtime[A, B]]

proc initPool*(pool: var Pool) =
  discard

proc drain*(pool: var Pool) =
  # initiate quits for all the runtimes
  for item in pool.mitems:
    quit item

  # remove runtimes as they terminate
  while not pool.head.isNil:
    let head = pool.head
    wait pool.head.value
    pool.remove head

proc fill*[A, B](pool: var Pool[A, B]): var Runtime[A, B] =
  var node: SinglyLinkedNode[Runtime[A, B]]
  new node
  pool.prepend node
  result = node.value

proc count*(pool: Pool): int =
  var head = pool.head
  while not head.isNil:
    inc result
    head = head.next
