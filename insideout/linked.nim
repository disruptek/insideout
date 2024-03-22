## a container for runtimes which is threadsafe;
## the impl doesn't really matter
##
## this structure should be ordered, as it's used
## to halt runtimes in reverse order
##
import std/genasts
import std/lists
import std/locks
import std/macros

import insideout/saferlists

type
  LinkedList*[T] = object
    lock: Lock
    list {.guard: lock.}: SinglyLinkedList[T]

proc isEmpty*[T](list: var LinkedList[T]): bool =
  withLock list.lock:
    result = list.list.isEmpty

proc len*[T](list: var LinkedList[T]): int =
  withLock list.lock:
    list.list.len

proc init*[T](list: var LinkedList[T]) =
  initLock list.lock

proc `=destroy`*[T](list: var LinkedList[T]) =
  withLock list.lock:
    reset list.list
  deinitLock list.lock

proc contains*[T](list: var LinkedList[T]; value: T): bool =
  withLock list.lock:
    result = not find(list.list, value).isNil

macro ifEmpty*[T](list: var LinkedList[T]; body: typed): untyped =
  let L = newDotExpr(list, ident"lock")
  let P = newDotExpr(list, ident"list")
  result = genAstOpt({}, L, P, body):
    withLock L:
      if P.isEmpty:
        body

macro link1*[T](parent: var LinkedList[T]; child: T; body: typed): untyped =
  let L = newDotExpr(parent, ident"lock")
  let P = newDotExpr(parent, ident"list")
  result = genAstOpt({}, L, P, body):
    withLock L:
      if find(P, child).isNil:
        P.add child
        body

macro unlink1*[T](parent: var LinkedList[T]; child: T; body: typed): untyped =
  let L = newDotExpr(parent, ident"lock")
  let P = newDotExpr(parent, ident"list")
  result = genAstOpt({}, L, P, body):
    withLock L:
      if P.remove child:
        body

proc tryPop*[T](list: var LinkedList[T]; value: var T): bool =
  withLock list.lock:
    result = not list.list.isEmpty
    if result:
      value = pop list.list
