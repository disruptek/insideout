# TODO: turn this into a continuation
#       remove the lock
import std/lists
import std/rlocks

import pkg/cps

import insideout/spec as iospec
import insideout/runtimes
import insideout/mailboxes
import insideout/pools/saferemove   # a hack around stdlib bug

type
  PoolNode {.used.} = SinglyLinkedNode[Runtime]
  PoolObj = object  ## a collection of runtimes
    lock: RLock
    list: SinglyLinkedList[Runtime]
  Pool* = AtomicRef[PoolObj]

proc `=copy`*(dest: var PoolObj; src: PoolObj) {.error.}

proc isEmpty*(pool: Pool): bool =
  assert not pool.isNil
  withRLock pool[].lock:
    result = pool[].list.head.isNil

proc drain(pool: var PoolObj): Runtime =
  withRLock pool.lock:
    if not pool.list.head.isNil:
      result = pool.list.head.value
      if pool.list.safeRemove(pool.list.head):
        debug "removed ", result, " from pool."
      else:
        #debug "race removing runtime from pool"
        raise Defect.newException "remove race"

proc drain*(pool: Pool): Runtime {.discardable.} =
  ## remove a runtime from the pool;
  ## has no effect if the pool is empty
  assert not pool.isNil
  drain pool[]

proc join(pool: var PoolObj) =
  withRLock pool.lock:
    for runtime in pool.list.mitems:
      debug "joining ", runtime, " in pool..."
      join runtime
      debug "joined."

proc join*(pool: Pool) =
  ## wait for all threads in the pool to complete
  assert not pool.isNil
  join pool[]

proc halt(pool: var PoolObj) =
  withRLock pool.lock:
    for item in pool.list.items:
      debug "halting ", item, " in pool..."
      halt item

proc halt*(pool: Pool) =
  ## command all threads in the pool to halt
  assert not pool.isNil
  halt pool[]

proc signal(pool: var PoolObj; sig: int) =
  withRLock pool.lock:
    for item in pool.list.items:
      debug "signal (", sig, ") ", item, " in pool..."
      signal(item, sig)

proc signal*(pool: Pool; sig: int) =
  ## command all threads in the pool to halt
  assert not pool.isNil
  signal(pool[], sig)

proc `=destroy`(pool: var PoolObj) =
  debug "destroying pool..."
  if not getCurrentException().isNil:
    halt pool
  join pool
  withRLock pool.lock:
    while not pool.list.head.isNil:
      discard drain pool
  deinitRLock pool.lock

proc add*(pool: Pool; runtime: Runtime) =
  ## add a supplied runtime to the pool
  assert not pool.isNil
  var node: SinglyLinkedNode[Runtime]
  new node
  node.value = runtime
  withRLock pool[].lock:
    debug "adding ", runtime, " to pool..."
    pool[].list.prepend node
    debug "added."

proc add*(pool: Pool; continuation: sink Continuation): Runtime {.discardable.} =
  ## move the given continuation to a new runtime, and add it to the pool
  assert not pool.isNil
  result = spawn continuation
  pool.add result

when false:
  proc spawn*(pool: Pool; factory: Factory;
                    mailbox: Mailbox[B]): Runtime {.discardable.} =
    ## add a new runtime to the pool using the given factory and mailbox
    assert not pool.isNil
    debug "spawning ", $A, " against ", $B, " mailbox"
    result = spawn(factory, mailbox)
    pool.add result
    debug "spawned."

  proc newPool*(factory: Factory): Pool =
    ## create a new, empty pool against the given factory
    new result
    initRLock result[].lock
    debug "created pool."

  proc newPool*(factory: Factory; mailbox: Mailbox[B];
                      initialSize: Natural = 0): Pool =
    ## create a new pool against the given factory and spawn
    ## `initialSize` runtimes, each with the given mailbox
    result = newPool(factory)
    var n = initialSize
    while n > 0:
      discard result.spawn(factory, mailbox)
      dec n

proc newPool*(): Pool =
  ## create a new, empty pool against the given factory
  new result
  initRLock result[].lock
  debug "created pool."

proc cancel*(pool: Pool) =
  ## cancel all threads in the pool
  assert not pool.isNil
  withRLock pool[].lock:
    for item in pool[].list.items:
      debug "cancelling ", item, " in pool..."
      cancel item
      debug "cancelled."

proc shutdown*(pool: Pool) =
  ## command all threads in the pool to halt,
  ## then wait for each of them to complete
  halt pool
  join pool

proc count*(pool: Pool): int =
  ## count the number of runtimes in the pool
  assert not pool.isNil
  withRLock pool[].lock:
    var head {.cursor.} = pool[].list.head
    while not head.isNil:
      inc result
      head = head.next

proc items*(pool: Pool): seq[Runtime] =
  ## recover the threads from the pool
  assert not pool.isNil
  withRLock pool[].lock:
    for item in pool[].list.mitems:
      result.add item

proc mitems*(pool: Pool): seq[Runtime] =
  pool.items

proc clear*(pool: Pool) =
  ## remove all runtimes from the pool
  while not pool.isEmpty:
    discard drain pool

template stop*(pool: Pool) =
  halt pool

proc `$`*(pool: Pool): string =
  ## return a string representation of the pool
  assert not pool.isNil
  withRLock pool[].lock:
    result = "Pool(" & $pool.count & ")"

template spawn*(pool: Pool; factory: Callback; mailbox: Mailbox; count: int = 1): untyped =
  ## spawn `count` runtimes using the given factory and mailbox,
  ## and add them to the pool
  var n = count
  while n > 0:
    pool.add:
      spawn factory.call(mailbox)
    dec n

template newPool*(factory: Callback; mailbox: Mailbox; initialSize = 0): untyped =
  ## spawn `count` runtimes using the given factory and mailbox,
  ## and add them to a new pool
  var pool = newPool()
  spawn(pool, factory, mailbox, initialSize)
  pool

template newPool*(factory: Callback): untyped =
  ## shim whatfer creating a new pool with a factory argument
  newPool()
