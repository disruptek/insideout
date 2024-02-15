import std/atomics
import std/posix

import pkg/balls

import insideout/futex

suite "futexes":
  ## wait()
  echo getThreadId()
  var x: Atomic[uint32]
  store(x, 1, order = moSequentiallyConsistent)
  check -1 == wait(x, 1, timeout = 0.01)
  check errno == ETIMEDOUT
  check ETIMEDOUT == checkWait wait(x, 1, timeout = 0.01)
  store(x, 2, order = moSequentiallyConsistent)
  check -1 == wait(x, 1, timeout = 0.01)
  check errno == EAGAIN
  check EAGAIN == checkWait wait(x, 1, timeout = 0.01)

  ## waitMask()
  store(x, 1, order = moSequentiallyConsistent)
  expect FutexError:
    discard -1 == waitMask(x, 1, 1)
  check -1 == waitMask(x, 2, 4)
  check errno == EAGAIN
  check EAGAIN == checkWait waitMask(x, 2, 4)
  check -1 == waitMask(x, 2, 4, timeout = 0.01)
  check errno == EAGAIN
  check EAGAIN == checkWait waitMask(x, 2, 4, timeout = 0.01)
  check -1 == waitMask(x, 1, 2, timeout = 0.01)
  check errno == ETIMEDOUT
  check ETIMEDOUT == checkWait waitMask(x, 1, 2, timeout = 0.01)
