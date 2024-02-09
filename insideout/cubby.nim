import std/atomics

import insideout/memalloc
import insideout/futex

# https://en.wikipedia.org/wiki/Peterson%27s_algorithm
#
# Peterson's algorithm is a concurrent programming algorithm for mutual
# exclusion that allows two processes to share a single-use resource
# without conflict, using only 3 bits of shared memory for communication.

const
  turn {.used.}: uint   = 0b0001   # turn=1 is writer, turn=0 is reader
  wmask {.used.}: uint  = 0b0010   # when set, the writer wants to write
  rmask {.used.}: uint  = 0b0100   # when set, the reader wants to read
  xmask {.used.}: uint  = 0b1000   # application-specific extra state
  mask {.used.}: uint   = 0b1111   # pointer tag is limited to 4-bits

type
  Futex32 {.used.} = object
    futex: Atomic[uint32]

  Futex64 {.used, packed.} = object
    pad32: uint32
    futex: Atomic[uint32]

when sizeof(pointer) == 8:
  type Futex = Futex64
elif sizeof(pointer) == 4:
  type Futex = Futex32

type
  Cubby*[T] {.union.} = object
    u: Atomic[uint]     # updating/measuring state
    f: Futex            # blocking wait and wake
    p: Atomic[pointer]  # towards data in the cubby

# the lower half of the pointer... which may also be the upper half
template lower(u: typed): untyped = cast[uint32](cast[Futex](u).futex)

template strip(u: typed): untyped =
  ## select the pointer and omit the state
  ((u) and (not mask))

proc `=copy`[T](c: var Cubby[T]; d: Cubby[T]) {.error: "cubbies cannot be copied".}

proc strip(p: pointer): pointer =
  ## select the pointer and omit the state
  cast[pointer](strip cast[uint](p))

proc load[T](c: var Cubby[T]): uint =
  ## retrieve the cubby and its state
  load(c.u, order = moSequentiallyConsistent)

proc get[T](c: var Cubby[T]): ptr T =
  ## recover typed pointer from the cubby
  cast[ptr T](strip (load c))

proc isEmpty*[T](c: var Cubby[T]): bool =
  ## true if the cubby is empty
  get(c).isNil

proc deallocCubby(p: pointer) =
  ## free a stale cubby pointer
  let p = strip p  # remove any mask
  if not p.isNil:
    ioAlignedDealloc(p, MemAlign)

proc assign[T](c: var Cubby[T]; value: pointer) =
  ## assign memory to the cubby
  var prior: pointer
  while true:
    if compareExchange(c.p, prior, value, order = moSequentiallyConsistent):
      deallocCubby(prior)  # free the prior pointer if necessary
      break

proc new*[T](c: var Cubby[T]) =
  ## allocate a new cubby
  var value = ioAlignedAlloc0(sizeof(T), MemAlign)
  if value.isNil:
    raise OSError.newException "out of memory for cubby"
  else:
    c.assign(value)

proc `=destroy`*[T](c: var Cubby[T]) =
  ## tear down the cubby
  c.assign(nil)

proc `[]`*[T](c: var Cubby[T]): var T =
  ## read/write the cubby
  if c.isEmpty:
    new c
  result = get(c)[]

proc `[]=`*[T](c: var Cubby[T]; value: sink T) =
  ## assign a value to the cubby
  if c.isEmpty:
    new c
  get(c)[] = value

proc blockingWrite*[T](c: var Cubby[T]; value: sink T) =
  ## write `value` to the cubby; blocks if reader is reading
  assert not c.isEmpty, "allocate the cubby first"
  var state = fetchOr(c.u, turn or wmask, order = moSequentiallyConsistent)
  checkWake wake(c.f.futex)
  # we know: whether the reader is reading, wants to read, or has yielded
  state = state or turn or wmask  # update our copy of the state
  try:
    while (turn or rmask) == (state and (turn or rmask)):  # turn=1, rmask=1
      checkWait wait(c.f.futex, lower(state))
      state = load c
    # we know: the reader doesn't want to read, has yielded, or both
    get(c)[] = value
  finally:
    discard fetchAnd(c.u, not wmask, order = moSequentiallyConsistent)
    checkWake wake(c.f.futex)

proc blockingRead*[T](c: var Cubby[T]): T =
  ## read from the cubby; blocks if writer is writing
  assert not c.isEmpty, "allocate the cubby first"
  var state = fetchOr(c.u, rmask, order = moSequentiallyConsistent)
  state = fetchAnd(c.u, not turn, order = moSequentiallyConsistent)
  checkWake wake(c.f.futex)
  # we know: whether the writer is writing, wants to write, or has yielded
  state = state and not turn  # update our copy of the state
  try:
    while wmask == (state and (turn or wmask)):  # turn=0, wmask=1
      checkWait wait(c.f.futex, lower(state))
      state = load c
    # we know: the writer doesn't want to write, has yielded, or both
    result = get(c)[]
  finally:
    discard fetchAnd(c.u, not rmask, order = moSequentiallyConsistent)
    checkWake wake(c.f.futex)

proc isReadBlocked*[T](c: var Cubby[T]): bool {.used.} =
  ## true if the reader is blocked
  # turn is 0, wmask is on
  assert not c.isEmpty, "allocate the cubby first"
  wmask == ((turn or wmask) and (load c))

proc isWriteBlocked*[T](c: var Cubby[T]): bool {.used.} =
  ## true if the writer is blocked
  # turn is 1, rmask is on
  assert not c.isEmpty, "allocate the cubby first"
  (turn or rmask) == ((turn or rmask) and (load c))

proc enable*[T](c: var Cubby[T]) =
  ## enable the extra state flag of the cubby
  assert not c.isEmpty, "allocate the cubby first"
  discard fetchOr(c.u, xmask, order = moSequentiallyConsistent)
  checkWake wake(c.f.futex)

proc disable*[T](c: var Cubby[T]) =
  ## disable the extra state flag of the cubby
  assert not c.isEmpty, "allocate the cubby first"
  discard fetchAnd(c.u, not xmask, order = moSequentiallyConsistent)
  checkWake wake(c.f.futex)

proc toggle*[T](c: var Cubby[T]) =
  ## flip the extra state flag of the cubby
  assert not c.isEmpty, "allocate the cubby first"
  discard fetchXor(c.u, xmask, order = moSequentiallyConsistent)
  checkWake wake(c.f.futex)

proc hasFlag*[T](c: var Cubby[T]): bool =
  ## true if the extra state flag is on
  assert not c.isEmpty, "allocate the cubby first"
  xmask == (xmask and (load c))
