# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/atomics
import std/math
import std/posix

type
  FutexError* = object of OSError
  FutexOp = enum
    Wait           = 0
    Wake           = 1
    FileDescriptor = 2
    Requeue        = 3
    CMPRequeue     = 4
    WakeOp         = 5
    LockPi         = 6
    UnlockPi       = 7
    TryLockPi      = 8
    WaitBitset     = 9
    WakeBitset     = 10
    WaitRequeuePi  = 11
    CMPRequeuePi   = 12
    LockPi2        = 13
    PrivateFlag    = 128
    ClockRealtime  = 256

const
  WaitPrivate = Wait.ord or PrivateFlag.ord
  WakePrivate = Wake.ord or PrivateFlag.ord
  WaitBitsPrivate = WaitBitset.ord or PrivateFlag.ord
  WakeBitsPrivate = WakeBitset.ord or PrivateFlag.ord

let NR_Futex {.importc: "__NR_futex", header: "<sys/syscall.h>".}: cint
proc syscall(sysno: clong): cint {.header:"<unistd.h>", varargs.}

proc sysFutex(uaddr: pointer; futex_op: cint; val: uint32;
              timeout: ptr TimeSpec = nil; uaddr2: ptr uint32 = nil;
              val3: uint32 = 0): cint =
  assert val != 0
  atomicThreadFence ATOMIC_SEQ_CST
  result = syscall(NR_Futex, uaddr, futex_op, val, timeout, uaddr2, val3)
  atomicThreadFence ATOMIC_SEQ_CST

proc getTimeSpec*(clock: ClockId): TimeSpec =
  if 0 != clock_gettime(clock, result):
    raise FutexError.newException "clock_gettime() failed"

proc toTimeSpec(timeout: float): TimeSpec =
  assert timeout >= 0.0
  result.tv_sec = Time timeout.floor
  result.tv_nsec = clong((timeout - result.tv_sec.float) * 1_000_000_000)

proc `+`*(a, b: TimeSpec): TimeSpec =
  result.tv_sec = Time(a.tv_sec.clong + b.tv_sec.clong)
  result.tv_nsec = a.tv_nsec + b.tv_nsec
  if result.tv_nsec >= 1_000_000_000:
    result.tv_sec = Time(result.tv_sec.clong + 1)
    result.tv_nsec -= 1_000_000_000

proc wait*[T](monitor: var Atomic[T]; compare: T): cint =
  ## Suspend a thread if the value of `monitor` is the same as `compare`.
  result = sysFutex(addr monitor, WaitPrivate, cast[uint32](compare))

proc wait*[T](monitor: var Atomic[T]; compare: T; timeout: float): cint =
  ## Suspend a thread if the value of `monitor` is the same as `compare`;
  ## resume after `timeout` seconds.
  var tm = timeout.toTimeSpec
  result = sysFutex(addr monitor, WaitPrivate, cast[uint32](compare),
                    timeout = addr tm)

proc waitMask*[T](monitor: var Atomic[T]; compare: T; mask: uint32): cint =
  ## Suspend a thread until any of `mask` bits are set.
  if (mask and cast[uint32](compare)) != 0:
    raise FutexError.newException "mask and compare overlap"
  else:
    result = sysFutex(addr monitor, WaitBitsPrivate,
                      cast[uint32](compare), val3 = mask)

proc waitMask*[T](monitor: var Atomic[T]; compare: T; mask: uint32;
                  timeout: float): cint =
  ## Suspend a thread until any of `mask` bits are set;
  ## resume after `timeout` seconds.
  if (mask and cast[uint32](compare)) != 0:
    raise FutexError.newException "mask and compare overlap"
  else:
    var tm = getTimeSpec(CLOCK_MONOTONIC) + timeout.toTimeSpec
    result = sysFutex(addr monitor, WaitBitsPrivate, cast[uint32](compare),
                      timeout = addr tm, val3 = mask)

proc wake*[T](monitor: var Atomic[T]; count = high(uint32)): cint {.discardable.} =
  ## Wake as many as `count` threads from the same process.
  # Returns the number of actually woken threads
  # or a Posix error code (if negative).
  result = sysFutex(addr monitor, WakePrivate, count)

proc wakeMask*[T](monitor: var Atomic[T]; mask: uint32; count = high(uint32)): cint {.discardable.} =
  ## Wake as many as `count` threads from the same process,
  ## which are all waiting on any set bit in `mask`.
  # Returns the number of actually woken threads
  # or a Posix error code (if negative).
  if mask == 0:
    raise FutexError.newException "missing 32-bit mask"
  else:
    result = sysFutex(addr monitor, WakeBitsPrivate, count, val3 = mask)

proc checkWait*(err: cint): cint {.discardable.} =
  if -1 == err:
    result = errno
    case errno
    of EINTR, EAGAIN, ETIMEDOUT:
      discard
    else:
      raise FutexError.newException $strerror(errno)
  else:
    result = err

proc checkWake*(err: cint): cint {.discardable.} =
  if -1 == err:
    result = errno
    raise FutexError.newException $strerror(errno)
  else:
    result = err
