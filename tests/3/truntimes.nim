import std/atomics
import std/os

import pkg/balls
import pkg/cps

import insideout/runtimes
import insideout/mailboxes
#import insideout/backlog
import insideout/valgrind

let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    10_000
  else:
    50_000

type
  Server = ref object of Continuation
  Job = ref object

proc cooperate(c: Continuation): Continuation {.cpsMagic.} = c

proc unblocking(jobs: Mailbox[Job]) {.cps: Server.} =
  ## non-blocking receive
  #debug "service began"
  while true:
    var job: Job
    case jobs.tryRecv(job)
    of Received:
      discard
    of Unreadable:
      #debug "service lost input"
      break
    else:
      #debug "service waiting"
      if not jobs.waitForPoppable():
        #debug "service wait failed"
        break
    cooperate()
  #debug "service ended"

proc blocking(jobs: Mailbox[Job]) {.cps: Server.} =
  ## blocking receive
  #debug "service began"
  while true:
    #debug "service waiting"
    var job = recv jobs
    cooperate()
  #debug "service ended"

const Unblocking = whelp unblocking
const Blocking = whelp blocking

proc main() =

  block:
    ## non-blocking mailbox sniffer
    #notice "runtime"
    let jobs = newMailbox[Job]()
    #info "[runtime] spawn"
    var runtime = Unblocking.spawn(jobs)
    var other = runtime
    doAssert other.state == Running
    doAssert other == runtime
    #info "[runtime] pin"
    pinToCpu(other, 0)
    doAssert runtime.mailbox == jobs
    var job = Job()
    #info "[runtime] send"
    while Delivered != jobs.trySend(job):
      discard
    #info "[runtime] close"
    jobs.disablePush()
    #info "[runtime] join"
    join runtime
    #info "[runtime] done"

  when false: #block:
    ## blocking waitor cancellation
    notice "cancellation"
    var jobs = newMailbox[Job]()
    info "[cancel] spawn"
    var runtime = Blocking.spawn(jobs)
    info "[cancel] cancel"
    cancel runtime
    info "[cancel] join"
    join runtime
    info "[cancel] done"

for i in 1..N:
  main()
