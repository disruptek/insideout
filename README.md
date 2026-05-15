# insideout

This is an experimental concurrency runtime for Nim.

[![Test Matrix](https://github.com/disruptek/insideout/workflows/CI/badge.svg)](https://github.com/disruptek/insideout/actions?query=workflow%3ACI)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/disruptek/insideout?style=flat)](https://github.com/disruptek/insideout/releases/latest)
![Minimum supported Nim version](https://img.shields.io/badge/nim-1.9.3-informational?style=flat&logo=nim)
[![License](https://img.shields.io/github/license/disruptek/insideout?style=flat)](#license)
[![IRC](https://img.shields.io/badge/chat-%23%23disruptek%20on%20libera.chat-brightgreen?style=flat)](https://web.libera.chat/##disruptek)

We think it's easier to move continuations from thread to thread than it is
to move arbitrary data. We offer API that lets you imperatively move your
continuation to other thread pools without any locking or copies.

This experiment has expanded to support detached threads, channels with
backpressure, lock-free queues, and a "local" event queue for I/O and signal
handling.

## Goals

- extremely high efficiency, *but*
- favor generality over performance
- zero-copy migration among threads
- lock-free without busy loops
- detached threads for robustness
- idiomatic; minimal boilerplate
- standard `Continuation` passing
- arbitrary `ref` and `ptr` passing
- expose thread affinity, attributes
- event queue included for I/O
- enable incremental CPS adoption
- be the concurrency-lib's toolkit

## Performance

Adequate.

Inside a single thread, concurrency is cooperative and lock-free, so if you
don't yield to the dispatcher, your continuation may only be interrupted by a
signal from another thread. At present, the only occasions for interruption are
when you call `halt()` on a thread, or use the pause/resume functions named
`freeze()` and `thaw()`.

## Efficiency

Empty continuations are 40-bytes each.  Queue overhead is 10-bytes per object.
One billion queued continuations thus occupies 50gb of memory.

Toys are starting to run a little more slowly due to overhead from things like
thread cancellation, signal handling and, more generally, the event queue.

That said, the tests demonstrate using the (richest) API to run millions of
continuations per second on modern desktop hardware.

## Support

insideout supports `define:useMalloc`, `mm:arc`, `backend:c`,
and POSIX threads. insideout does not support `mm:orc`.

insideout is primarily developed using
[Nimskull](https://github.com/nim-works/nimskull)
and may not work with mainline Nim.

insideout is tested with compiler sanitizers to make sure it doesn't
demonstrate memory leaks or data-races.

### ThreadSanitizer (TSAN)

When running tests with TSAN (`balls --define:danger`), you may see benign false
positive warnings about data races in the loony queue's atomic refcount operations.
These false positives occur because TSAN is overly conservative about memory
ordering in lock-free queue patterns that use atomicThreadFence for synchronization.

To suppress these false positives, set the TSAN_OPTIONS environment variable:

```bash
TSAN_OPTIONS="suppressions=$(pwd)/tsan-suppressions.txt" balls --define:danger
```

See `tsan-suppressions.txt` for details on why these warnings are safe to ignore.

## macOS

insideout targets Linux first; macOS (and the BSDs) are supported on a
best-effort basis. The Linux build is unaffected: every macOS-specific code
path sits behind a `when defined(macosx) or defined(darwin) or defined(bsd)`
guard, and the `else` branch reproduces the original Linux behaviour.

### What is emulated

macOS exposes no public equivalent of several Linux primitives, so they are
emulated:

- **futex** — emulated with the *undocumented* `__ulock_wait` / `__ulock_wake`
  syscalls. These are the closest match to Linux futexes (address-based
  waiting with no extra state) and are used by Go, Rust's `std`, and WebKit
  for the same reason. Because they are undocumented, Apple may change them
  between OS releases, and binaries that use them cannot be shipped through
  the Mac App Store.
- **epoll** — replaced with `kqueue(2)`: timers use `EVFILT_TIMER`, I/O uses
  `EVFILT_READ` / `EVFILT_WRITE`.
- **signalfd** — macOS cannot poll signals through a file descriptor, so a
  dedicated signal thread waits on `EVFILT_SIGNAL` and forwards each caught
  signal number through a pipe; the read end of that pipe stands in for the
  signalfd.
- **timerfd** — `sleep` arms a fd-less one-shot `EVFILT_TIMER` instead.
- **SIGRTMIN** — macOS has no realtime signals, so `SIGUSR1` is used as the
  thread-interruption signal.

### Building on macOS

The same flags as Linux apply (see *Support* above): `--define:useMalloc`,
`--mm:arc`, `--backend:c`. No macOS-specific flags are required.

If the stability of the undocumented `__ulock` syscalls ever becomes a
problem, a slower `pthread_cond`-based fallback could be added; it is not
implemented today.

### Tests

macOS-specific behaviour is covered by `tests/t*_*_macos.nim`. Those files are
themselves `when`-guarded to Darwin/BSD and are inert on other platforms; each
file documents, at its top, what it asserts and why.

## Documentation

Nim's documentation generator breaks when attempting to read insideout.

Define `insideoutValgrind=on` to enable Valgrind-specific annotations.

## License
MIT
