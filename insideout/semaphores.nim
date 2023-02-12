import std/genasts
import std/locks

import insideout/monkeys

type
  Semaphore* = object
    lock: Lock
    cond: Cond
    count: int

proc initSemaphore*(s: var Semaphore; count: int = 0) =
  ## Initialize a Semaphore for use.
  initLock s.lock
  initCond s.cond
  s.count = count

proc `=destroy`*(s: var Semaphore) =
  deinitLock s.lock
  deinitCond s.cond
  s.count = 0

proc `=copy`*(s: var Semaphore; e: Semaphore)
  {.error: "Semaphore cannot be copied".} =
  ## Semaphore cannot be copied.
  discard

macro withLock*(s: var Semaphore; logic: typed) =
  ## run the `logic` while holding the Semaphore `s`'s lock
  genAstOpt({}, s, logic):
    sleepyMonkey()
    acquire s.lock
    {.locks: [s.lock].}:
      try:
        logic
      finally:
        sleepyMonkey()
        release s.lock

proc signal*(s: var Semaphore) =
  ## blocking signal of `s`; increments Semaphore
  withLock s:
    inc s.count
    # FIXME: move this out eventually
    # here because of drd?  --report-signal-unlocked=no
    sleepyMonkey()
    signal s.cond

proc wait*(s: var Semaphore) =
  ## Blocking wait on `s`; decrements Semaphore.
  template consume {.dirty.} =
    if s.count > 0:
      dec s.count
      sleepyMonkey()
      release s.lock
      break
  while true:
    sleepyMonkey()
    acquire s.lock
    {.locks: [s.lock].}:
      consume  # fast path
      sleepyMonkey()
      wait(s.cond, s.lock)
      consume  # slow path
      sleepyMonkey()
      release s.lock

proc gate*(s: var Semaphore) =
  ## blocking wait on `s`, followed by a signal
  withLock s:
    sleepyMonkey()
    wait(s.cond, s.lock)
    sleepyMonkey()
    signal s.cond

proc available*(s: var Semaphore): int =
  ## blocking count of `s`
  withLock s:
    result = s.count

proc inc*(s: var Semaphore; value: int = 1) =
  ## blocking adhoc adjustment of the Semaphore
  withLock s:
    inc(s.count, value)

proc dec*(s: var Semaphore; value: int = 1) =
  ## blocking adhoc adjustment of the Semaphore
  withLock s:
    dec(s.count, value)

template withSemaphore*(s: var Semaphore; logic: typed): untyped =
  ## wait for the Semaphore `s`, run the `logic`, and signal it
  wait s
  try:
    logic
  finally:
    signal s

macro tryWait*(s: var Semaphore): bool =
  ## Non-blocking wait which returns true if successful.
  genAstOpt({}, s):
    sleepyMonkey()
    if tryAcquire s.lock:
      if s.count > 0:
        dec s.count
        sleepyMonkey()
        release s.lock
        true
      else:
        sleepyMonkey()
        release s.lock
        false
    else:
      false
