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

proc sysFutex(futex: pointer; op: cint; val: uint32; timeout: pointer = nil;
              uaddr2: pointer = nil; val3: uint32 = 0): cint =
  syscall(NR_Futex, futex, op, val, timeout, uaddr2, val3)

proc wait*[T](monitor: var Atomic[T]; compare: T): cint =
  ## Suspend a thread if the value of the futex is the same as refVal.
  sysFutex(addr monitor, WaitPrivate, cast[uint32](compare))

proc wait*[T](monitor: var Atomic[T]): cint =
  ## Suspend a thread until the value of the futex changes.
  sysFutex(addr monitor, WaitPrivate, cast[uint32](monitor))

proc waitMask*[T](monitor: var Atomic[T]; compare: T; mask: uint32): cint =
  ## Suspend a thread until any of `mask` bits are set.
  sysFutex(addr monitor, WaitBitsPrivate, cast[uint32](compare), val3 = mask)

proc waitMask*[T](monitor: var Atomic[T]; compare: T; mask: uint32;
                  timeout: float): cint =
  ## Suspend a thread until any of `mask` bits are set;
  ## give up waiting after `timeout` seconds.
  var tm: Timespec
  tm.tv_sec = Time timeout.floor
  tm.tv_nsec = clong((timeout - tm.tv_sec.float) * 1_000_000_000)
  sysFutex(addr monitor, WaitBitsPrivate, cast[uint32](compare),
           timeout = cast[pointer](addr tm), val3 = mask)

proc waitMask*[T](monitor: var Atomic[T]; mask: uint32; timeout: float): cint =
  ## Suspend a thread until any of `mask` bits are set;
  ## give up waiting after `timeout` seconds.
  waitMask(monitor, cast[T](monitor), mask, timeout)

proc waitMask*[T](monitor: var Atomic[T]; mask: uint32): cint =
  ## Suspend a thread until any of `mask` bits are set.
  sysFutex(addr monitor, WaitBitsPrivate, cast[cint](monitor),
           val3 = cast[cint](mask))

proc wake*[T](monitor: var Atomic[T]; count = high(uint32)): cint {.discardable.} =
  ## Wake as many as `count` threads from the same process.
  # Returns the number of actually woken threads
  # or a Posix error code (if negative).
  sysFutex(addr monitor, WakePrivate, count)

proc wakeMask*[T](monitor: var Atomic[T]; mask: uint32; count = high(uint32)): cint {.discardable.} =
  ## Wake as many as `count` threads from the same process,
  ## which are all waiting on any set bit in `mask`.
  # Returns the number of actually woken threads
  # or a Posix error code (if negative).
  sysFutex(addr monitor, WakeBitsPrivate, count, val3 = cast[uint32](mask))

proc checkWait*(err: cint): cint {.discardable.} =
  if err >= 0: return err
  case errno
  #of ETIMEDOUT:
  #  echo getThreadId(), " stall!"
  of EINTR, EAGAIN, ETIMEDOUT:
    return errno
  else:
    raise ValueError.newException $strerror(errno)
