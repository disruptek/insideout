## Another simple test of runtimes in which we whelp two different forms
## of continuation and send them to the same mailbox for execution on
## a runtime. (The second continuation is enqueued but then ignored.)
##
## The server continuation receives a continuation from the mailbox
## synchronously and runs it without returning control to the runtime.
##
## The runtime exits, is joined by the main thread, and will correctly
## free its memory, including the server continuation and the mailbox.

## This test has evolved to also test allocation/deallocation across
## runtimes to ensure that we're running these hooks correctly.

import std/atomics
import std/os
import std/strutils

import pkg/cps

import insideout/runtimes
import insideout/mailboxes
import insideout/valgrind
import insideout/spec

let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    1_000
  else:
    10_000

type
  Amplifier = ref object of Continuation
    volume: ref int

  Speaker = ref object of Continuation
    frequency: ref float

  Either = Speaker or Amplifier

var memops: Atomic[int]

proc destroy(c: var Either) =
  if c.isNil:
    raise Defect.newException "dealloc on nil continuation"
  else:
    when c is Amplifier:
      if c.volume.isNil:
        raise Defect.newException "dealloc on uninit continuation"
      else:
        discard fetchAdd(memops, 1)
        reset c.volume
    elif c is Speaker:
      if c.frequency.isNil:
        raise Defect.newException "dealloc on uninit continuation"
      else:
        discard fetchAdd(memops, 1)
        reset c.frequency
    c = nil

proc alloc[T: Amplifier](U: typedesc[T]; E: typedesc): E =
  discard fetchAdd(memops, 1)
  new result

proc dealloc[T: Amplifier](c: sink T; E: typedesc[T]): E =
  destroy c
  c = nil

proc alloc(U: typedesc[Speaker]; E: typedesc): E =
  discard fetchAdd(memops, 1)
  new result

proc dealloc[T: Speaker](c: sink T; E: typedesc[T]): E =
  destroy c
  c = nil

proc setVolume(c: sink Amplifier; vol: int): Amplifier {.cpsMagic.} =
  new c.volume
  c.volume[] = vol
  c

proc getVolume(c: sink Amplifier): int {.cpsVoodoo.} =
  c.volume[]

proc server(jobs: Mailbox[Speaker]) {.cps: Amplifier.} =
  setVolume 11
  var job = recv jobs
  while job.running:
    job = bounce(move job)
  if not job.isNil:
    echo "vol: ", getVolume(), " freq: ", job.frequency[]
    job = dealloc(job, Speaker)

proc setFrequency(c: sink Speaker; freq: float): Speaker {.cpsMagic.} =
  new c.frequency
  c.frequency[] = freq
  c

proc sing(freq: float; message: string) {.cps: Speaker.} =
  setFrequency freq
  echo message

proc shout(freq: float; message: string) {.cps: Speaker.} =
  setFrequency freq
  echo message.toUpper

const Factory = whelp server

proc main =
  memops.store 0

  var queue = newMailbox[Speaker]()

  # 1
  queue.send:
    whelp shout(3.5, "i said, 'hello, world!'")

  # 2
  var c = whelp server(queue)
  c = trampoline c
  c = dealloc(Amplifier c, server{cpsEnvironment})

  # 3
  queue.send:
    whelp sing(5.3, "hello, world!")

  # 4
  server(queue)

  # 5
  queue.send:
    whelp sing(8.3, "hello, world!")

  # 6
  var service = spawn(Factory, queue)
  join service

  doAssert memops.load == 6*2

for _ in 1..N:
  main()
