import std/genasts
import std/hashes
import std/locks

type
  Semaphore* = object
    lock: Lock
    cond: Cond
    count: int

proc hash*(s: var Semaphore): Hash =
  ## whatfer inclusion in a table, etc.
  hash(cast[int](addr s))

proc initSemaphore*(s: var Semaphore; count: int = 0) =
  ## make a semaphore available for use
  initLock s.lock
  initCond s.cond
  s.count = count

proc `=destroy`*(s: var Semaphore) =
  deinitLock s.lock
  deinitCond s.cond
  s.count = 0

proc `=copy`*(s: var Semaphore; e: Semaphore)
  {.error: "semaphores cannot be copied".} =
  discard

proc acquire*(s: var Semaphore) =
  ## adhoc acquire of semaphore's lock
  acquire s.lock

proc release*(s: var Semaphore) =
  ## adhoc release of semaphore's lock
  release s.lock

proc signal*(s: var Semaphore) =
  ## blocking signal of `s`; increments semaphore
  withLock s.lock:
    inc s.count
    signal s.cond

proc wait*(s: var Semaphore) =
  ## blocking wait on `s`
  template consume(s: Semaphore) =
    try:
      if s.count > 0:
        dec s.count
        break
    finally:
      release s.lock

  while true:
    acquire s.lock
    consume s
    # unavailable; wait and retry
    wait(s.cond, s.lock)
    consume s

proc available*(s: var Semaphore): int =
  ## blocking count of `s`
  withLock s.lock:
    result = s.count

template isReady*(s: var Semaphore): untyped =
  ## blocking `true` if `s` is ready
  s.available > 0

proc inc*(s: var Semaphore) =
  ## blocking adhoc adjustment of the semaphore
  withLock s.lock:
    inc s.count

proc dec*(s: var Semaphore) =
  ## blocking adhoc adjustment of the semaphore
  withLock s.lock:
    dec s.count

macro withSemaphore*(s: var Semaphore; logic: typed): untyped =
  ## blocking wait on `s`; run `logic` before release
  let consume =
    genAstOpt({}, s, logic):
      try:
        if s.count > 0:
          dec s.count
          logic
          break
      finally:
        release s.lock
  result =
    genAstOpt({}, s, consume):
      while true:
        acquire s.lock
        consume
        # unavailable; wait and retry
        wait(s.cond, s.lock)
        consume
