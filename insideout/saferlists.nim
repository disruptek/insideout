## just a little comfort around linked lists
import std/lists
export lists

proc safeRemove*[T](L: var SinglyLinkedList[T], n: SinglyLinkedNode[T]): bool {.discardable.} =
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

proc remove*[T](list: var SinglyLinkedList[T]; value: T): bool {.discardable.} =
  ## remove a value from a linked list;
  ## true if the value was found and removed
  var node = list.find(value)
  result = not node.isNil
  if result:
    result = list.safeRemove node

template isEmpty*[T](list: SinglyLinkedList[T]): bool = list.head.isNil

proc len*[T](list: SinglyLinkedList[T]): int =
  var head {.cursor.} = list.head
  while not head.isNil:
    inc result
    head = head.next

proc pop*[T](list: var SinglyLinkedList[T]): T =
  ## remove and return the last element of the list
  if list.head.isNil:
    raise IndexDefect.newException "pop from empty list"
  var head = list.head
  if head.next.isNil:
    list.head = nil
    result = head.value
  else:
    var prev = head
    while not prev.next.next.isNil:
      prev = prev.next
    result = prev.next.value
    prev.next = nil
