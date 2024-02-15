# TODO: turn this into a continuation
#       remove the lock
import std/lists
import std/rlocks

import pkg/cps

import insideout/runtimes
import insideout/mailboxes
#import insideout/backlog
import insideout/pools/saferemove   # a hack around stdlib bug

when false:
  import insideout/backlog
  export backlog
else:
  template debug(args: varargs[untyped]) = discard

type
  PoolNode[A, B] {.used.} = SinglyLinkedNode[Runtime[A, B]]
  PoolObj[A, B] = object  ## a collection of runtimes
    lock: RLock
    list: SinglyLinkedList[Runtime[A, B]]
  Pool*[A, B] = AtomicRef[PoolObj[A, B]]

proc `=copy`*[A, B](dest: var PoolObj[A, B]; src: PoolObj[A, B]) {.error.}

proc isEmpty[A, B](pool: var PoolObj[A, B]): bool =
  withRLock pool.lock:
    result = pool.list.head.isNil

proc isEmpty*[A, B](pool: var Pool): bool =
  assert not pool.isNil
  pool[].isEmpty

proc drain[A, B](pool: var PoolObj[A, B]): Runtime[A, B] =
  withRLock pool.lock:
    if not pool.list.head.isNil:
      result = pool.list.head.value
      if pool.list.safeRemove(pool.list.head):
        debug "removed ", result, " from pool."
      else:
        #debug "race removing runtime from pool"
        raise Defect.newException "remove race"

proc drain*[A, B](pool: var Pool[A, B]): Runtime[A, B] {.discardable.} =
  ## remove a runtime from the pool;
  ## has no effect if the pool is empty
  assert not pool.isNil
  drain pool[]

proc join[A, B](pool: var PoolObj[A, B]) =
  withRLock pool.lock:
    for runtime in pool.list.mitems:
      debug "joining ", runtime, " in pool..."
      join runtime
      debug "joined."

proc join*[A, B](pool: var Pool[A, B]) =
  ## wait for all threads in the pool to complete
  assert not pool.isNil
  join pool[]

proc halt[A, B](pool: var PoolObj[A, B]) =
  withRLock pool.lock:
    for item in pool.list.items:
      debug "halting ", item, " in pool..."
      halt item
      debug "halted."

proc halt*[A, B](pool: var Pool[A, B]) =
  ## command all threads in the pool to halt
  assert not pool.isNil
  halt pool[]

proc `=destroy`[A, B](pool: var PoolObj[A, B]) =
  debug "destroying pool..."
  if not getCurrentException().isNil:
    halt pool
  join pool
  while not pool.isEmpty:
    discard drain pool
  deinitRLock pool.lock

proc add*[A, B](pool: var Pool[A, B]; runtime: Runtime[A, B]) =
  ## add a supplied runtime to the pool
  assert not pool.isNil
  var node: SinglyLinkedNode[Runtime[A, B]]
  new node
  node.value = runtime
  withRLock pool[].lock:
    debug "adding ", runtime, " to pool..."
    pool[].list.prepend node
    debug "added."

proc spawn*[A, B](pool: var Pool[A, B]; factory: Factory[A, B];
                  mailbox: Mailbox[B]): Runtime[A, B] {.discardable.} =
  ## add a new runtime to the pool using the given factory and mailbox
  assert not pool.isNil
  debug "spawning ", $A, " against ", $B, " mailbox"
  result = spawn(factory, mailbox)
  pool.add result
  debug "spawned."

proc newPool*[A, B](factory: Factory[A, B]): Pool[A, B] =
  ## create a new, empty pool against the given factory
  new result
  initRLock result[].lock
  debug "created pool."

proc newPool*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B];
                    initialSize: Natural = 0): Pool[A, B] =
  ## create a new pool against the given factory and spawn
  ## `initialSize` runtimes, each with the given mailbox
  result = newPool(factory)
  var n = initialSize
  while n > 0:
    discard result.spawn(factory, mailbox)
    dec n

proc cancel*[A, B](pool: Pool[A, B]) =
  ## cancel all threads in the pool
  assert not pool.isNil
  withRLock pool[].lock:
    for item in pool[].list.items:
      debug "cancelling ", item, " in pool..."
      cancel item
      debug "cancelled."

proc shutdown*[A, B](pool: Pool[A, B]) =
  ## command all threads in the pool to halt,
  ## then wait for each of them to complete
  halt pool
  join pool

proc count*[A, B](pool: Pool[A, B]): int =
  ## count the number of runtimes in the pool
  assert not pool.isNil
  withRLock pool[].lock:
    var head {.cursor.} = pool[].list.head
    while not head.isNil:
      inc result
      head = head.next

proc items*[A, B](pool: Pool[A, B]): seq[Runtime[A, B]] =
  ## recover the threads from the pool
  assert not pool.isNil
  withRLock pool[].lock:
    for item in pool[].list.mitems:
      result.add item

proc mitems*[A, B](pool: Pool[A, B]): seq[Runtime[A, B]] =
  pool.items

proc empty*[A, B](pool: Pool[A, B]) =
  ## remove all runtimes from the pool
  while not pool.isEmpty:
    discard drain pool

template stop*[A, B](pool: Pool[A, B]) =
  halt pool

proc `$`*[A, B](pool: Pool[A, B]): string =
  ## return a string representation of the pool
  assert not pool.isNil
  withRLock pool[].lock:
    result = "Pool[" & $A & ", " & $B & "](" & $pool.count & ")"
