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

template withLock*(s: var Semaphore; logic: untyped) =
  ## run the `logic` while holding the semaphore `s`'s lock
  acquire s
  try:
    logic
  finally:
    release s

proc signal*(s: var Semaphore) =
  ## blocking signal of `s`; increments semaphore
  withLock s.lock:
    inc s.count
    # FIXME: move this out eventually
    # here because of drd?  --report-signal-unlocked=no
    signal s.cond

proc wait*(s: var Semaphore) =
  ## blocking wait on `s`
  template consume {.dirty.} =
    if s.count > 0:
      dec s.count
      release s.lock
      break
  while true:
    acquire s.lock
    consume
    wait(s.cond, s.lock)
    consume
    release s.lock

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

macro withLockedSemaphore*(s: var Semaphore; logic: typed): untyped =
  ## block until `s` is available,
  ## consume it, and
  ## run `logic` while holding the lock
  genAstOpt({}, s, logic):
    while true:
      acquire s.lock
      if s.count > 0:
        try:
          dec s.count
          logic
          break
        finally:
          release s.lock
      wait(s.cond, s.lock)
      release s.lock

template withSemaphore*(s: var Semaphore; logic: typed): untyped =
  ## wait for the semaphore `s`, run the `logic`, and signal it
  wait s
  try:
    logic
  finally:
    signal s

template trySemaphore*(s: var Semaphore; logic: typed): untyped =
  if tryAcquire s.lock:
    if s.count > 0:
      dec s.count
      try:
        logic
      finally:
        release s.lock
      true
    else:
      release s.lock
      false
  else:
    false
