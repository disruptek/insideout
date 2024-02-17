import std/atomics
import std/math
import std/os
import std/osproc

import pkg/cps

import insideout
import insideout/valgrind

var ntotal: Atomic[int]

proc main4d(mail: Mailbox[Continuation]; n: int) {.cps: Continuation.} =
  ntotal += 1

proc main4c(mail: Mailbox[Continuation]; n: int) {.cps: Continuation.} =
  ntotal += 1
  var i = 0
  while i < n:
    mail.send: whelp main4d(mail, n)
    inc i

proc main4b(mail: Mailbox[Continuation]; n: int) {.cps: Continuation.} =
  ntotal += 1
  var i = 0
  while i < n:
    mail.send: whelp main4c(mail, n)
    inc i

proc main4a(mail: Mailbox[Continuation]; n: int) {.cps: Continuation.} =
  ntotal += 1
  var i = 0
  while i < n:
    mail.send: whelp main4b(mail, n)
    inc i

proc main4(mail: Mailbox[Continuation]; n: int) {.cps: Continuation.} =
  ntotal += 1
  var i = 0
  while i < n:
    stderr.write(".")
    mail.send: whelp main4a(mail, n)
    inc i

proc go() =

  var count = 50
  when not defined(danger):
    count = 20
  if isUnderValgrind() or isSanitizing():
    echo "valgrind/sanitizer detected"
    count = 7

  var cores = countProcessors() div 2
  var mail = newMailbox[Continuation]()
  var pool = newPool(ContinuationWaiter, mail, initialSize = cores)

  mail.send: whelp main4(mail, count)
  echo "hatched"

  let total = (count ^ 0) + (count ^ 1) + (count ^ 2) + (count ^ 3) + (count ^ 4)
  echo total

  while true:
    let n = ntotal.load()
    echo n
    if n == total:
      break
    os.sleep(50)

  closeWrite mail
  echo "all good"

go()
