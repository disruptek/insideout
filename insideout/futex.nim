# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

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

proc sysFutex(futex: pointer; op: cint; val1: cint; timeout: pointer = nil;
              val2: pointer = nil; val3: cint = 0): cint {.inline.} =
  syscall(NR_Futex, futex, op, val1, timeout, val2, val3)

proc wait*[T](monitor: var T; compare: T): cint {.inline.} =
  ## Suspend a thread if the value of the futex is the same as refVal.
  sysFutex(addr monitor, WaitPrivate, cast[cint](compare))

proc wait*[T](monitor: var T): cint {.inline.} =
  ## Suspend a thread until the value of the futex changes.
  sysFutex(addr monitor, WaitPrivate, cast[cint](monitor))

proc waitMask*[T](monitor: var T; compare: T; mask: uint32): cint {.inline.} =
  ## Suspend a thread until any of `mask` bits are set.
  sysFutex(addr monitor, WaitBitsPrivate, cast[cint](compare),
           val3 = cast[cint](mask))

proc waitMask*[T](monitor: var T; mask: uint32): cint {.inline.} =
  ## Suspend a thread until any of `mask` bits are set.
  sysFutex(addr monitor, WaitBitsPrivate, cast[cint](monitor),
           val3 = cast[cint](mask))

proc wake*[T](monitor: var T; count = high(cint)): cint {.discardable, inline.} =
  ## Wake as many as `count` threads from the same process.
  # Returns the number of actually woken threads
  # or a Posix error code (if negative).
  sysFutex(addr monitor, WakePrivate, count)

proc wakeMask*[T](monitor: var T; mask: uint32; count = high(cint)): cint {.discardable, inline.} =
  ## Wake as many as `count` threads from the same process,
  ## which are all waiting on any set bit in `mask`.
  # Returns the number of actually woken threads
  # or a Posix error code (if negative).
  sysFutex(addr monitor, WakeBitsPrivate, count, val3 = cast[cint](mask))

template checkWait*(waited: cint): untyped =
  var e = waited
  if e < 0:
    e = -e
    case e
    of EPERM:
      stderr.write("EPERM on futex wait\n")
    of EINTR, EAGAIN:
      discard
    else:
      raise ValueError.newException $strerror(e)
