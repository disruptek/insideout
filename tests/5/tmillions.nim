import std/math
import std/atomics
import std/os

import pkg/cps
import insideout
import insideout/valgrind

var ntotal: Atomic[int]

var mail = newMailbox[Continuation]()
proc main4d(n: int) {.cps: Continuation.} =
  ntotal += 1
  discard

proc main4c(n: int) {.cps: Continuation.} =
  ntotal += 1
  var i = 0
  while i < n:
    mail.send: whelp main4d(n)
    inc i

proc main4b(n: int) {.cps: Continuation.} =
  ntotal += 1
  var i = 0
  while i < n:
    mail.send: whelp main4c(n)
    inc i

proc main4a(n: int) {.cps: Continuation.} =
  ntotal += 1
  var i = 0
  while i < n:
    mail.send: whelp main4b(n)
    inc i

proc main4(n: int) {.cps: Continuation.} =
  ntotal += 1
  var i = 0
  while i < n:
    stderr.write(".")
    mail.send: whelp main4a(n)
    inc i


proc go() =

  var count = 50
  when not defined(release):
    count = 20
  if isUnderValgrind() or isSanitizing():
    echo "valgrind/sanitizer detected"
    count = 7

  var pool = newPool(ContinuationWaiter, mail, initialSize = 16)
  mail.send: whelp main4(count)
  echo "hatched"

  let total = (count ^ 0) + (count ^ 1) + (count ^ 2) + (count ^ 3) + (count ^ 4)
  echo total

  while true:
    let n = ntotal.load()
    echo n
    if n == total:
      break
    os.sleep(50)

  # exit the threads
  stop pool

go()
echo "all good"
