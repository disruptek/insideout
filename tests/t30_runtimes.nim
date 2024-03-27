import std/atomics
import std/os

import pkg/balls
import pkg/cps

import insideout/runtimes
import insideout/mailboxes
import insideout/backlog
import insideout/valgrind
import insideout/atomic/flags

let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    1_000
  else:
    10_000

type
  Server = ref object of Continuation
  Job = ref object

var began, ended: Atomic[bool]

proc unblocking(jobs: Mailbox[Job]) {.cps: Server.} =
  ## non-blocking receive
  coop()
  began.store(true)
  debug "service began"
  var job: Job
  while Received != jobs.tryRecv(job):
    if not jobs.waitForPoppable:
      break
  debug "service ended"
  ended.store(true)

const Unblocking = whelp unblocking

proc main() =

  block:
    ## non-blocking mailbox sniffer
    info "runtime"
    let jobs = newMailbox[Job]()
    info "[runtime] spawn"
    var runtime = Unblocking.spawn(jobs)
    var other = runtime
    doAssert not (other.flags && <<Halted)
    doAssert other == runtime
    #info "[runtime] pin"
    #pinToCpu(other, 0)
    #doAssert runtime.mailbox == jobs
    var job = Job()
    info "[runtime] send"
    while Delivered != jobs.trySend(job):
      discard
    info "[runtime] close"
    jobs.closeWrite()
    info "[runtime] join"
    join runtime
    info "[runtime] done"

  block:
    ## spawn frozen
    began.store(false)
    ended.store(false)
    info "flags: frozen"
    let jobs = newMailbox[Job]()
    info "[frozen] spawn"
    var runtime = Unblocking.spawn(jobs, {StartFrozen})
    doAssert runtime.flags && <<Frozen
    while runtime.flags && <<Boot:
      discard
    var job = Job()
    info "[frozen] send"
    while Delivered != jobs.trySend(job):
      discard
    info "[frozen] close"
    jobs.closeWrite()
    info "[frozen] thaw"
    while runtime.flags && <<!{Teardown, Running}:
      thaw runtime
    doAssert runtime.flags && <<!Frozen
    info "[frozen] join"
    join runtime
    info "[frozen] done"

  block:
    ## spawn fast
    began.store(false)
    ended.store(false)
    info "flags: fast"
    let jobs = newMailbox[Job]()
    info "[fast] spawn"
    var runtime = Unblocking.spawn(jobs, {DenyCancels, SkipPolling})
    doAssert runtime.flags && <<!{Cancels, Polling}
    while runtime.flags && <<!Running:
      discard
    while not began.load:
      discard
    info "[fast] halt"
    halt runtime
    when insideoutDeferredCancellation:
      cancel runtime
    when true:
      var job = Job()
      info "[fast] send"
      while Delivered != jobs.trySend(job):
        discard
      doAssert runtime.flags && <<Running
    else:
      doAssert runtime.flags && <<Running
    info "[fast] close"
    jobs.closeWrite()
    info "[fast] join"
    join runtime
    info "[fast] done"
    doAssert ended.load

for i in 1..N:
  main()
