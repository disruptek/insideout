# insideout

This is an experimental concurrency runtime for Nim.

The basic conceit is that it's easier to move continuations
from thread to thread than it is to move arbitrary data.

[![Test Matrix](https://github.com/disruptek/insideout/workflows/CI/badge.svg)](https://github.com/disruptek/insideout/actions?query=workflow%3ACI)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/disruptek/insideout?style=flat)](https://github.com/disruptek/insideout/releases/latest)
![Minimum supported Nim version](https://img.shields.io/badge/nim-1.9.3-informational?style=flat&logo=nim)
[![License](https://img.shields.io/github/license/disruptek/insideout?style=flat)](#license)
[![IRC](https://img.shields.io/badge/chat-%23%23disruptek%20on%20libera.chat-brightgreen?style=flat)](https://web.libera.chat/##disruptek)

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

## Support

insideout supports `define:useMalloc`, `mm:arc`, `backend:c`,
and POSIX threads. insideout does not support `mm:orc`.

insideout is primarily developed using
[Nimskull](https://github.com/nim-works/nimskull)
and may not work with mainline Nim.

insideout is tested with compiler sanitizers to make sure it doesn't
demonstrate memory leaks or data-races.

## Documentation

Nim's documentation generator breaks when attempting to read insideout.

Define `insideoutValgrind=on` to enable Valgrind-specific annotations.

## License
MIT
