import std/atomics

import pkg/balls
import pkg/cps

import insideout/runtimes
import insideout/mailboxes
import insideout/backlog

type
  Server = ref object of Continuation
  Job = ref object

proc cooperate(c: Continuation): Continuation {.cpsMagic.} = c

proc service(jobs: Mailbox[Job]) {.cps: Server.} =
  debug "service began"
  while true:
    var job: Job
    case jobs.tryRecv(job)
    of Received:
      discard
    of Unreadable:
      debug "service lost input"
      break
    else:
      debug "service waiting"
      if not jobs.waitForPoppable():
        debug "service wait failed"
        break
    cooperate()
  debug "service ended"

const Service = whelp service

proc main() =

  block:
    ## runtime
    notice "runtime"
    let jobs = newMailbox[Job]()
    info "[runtime] spawn"
    var runtime = Service.spawn(jobs)
    var other = runtime
    doAssert other.state == Running
    doAssert other == runtime
    pinToCpu(other, 0)
    doAssert runtime.mailbox == jobs
    var job = Job()
    info "[runtime] send"
    jobs.send job
    info "[runtime] close"
    jobs.disablePush()
    info "[runtime] join"
    join runtime
    info "[runtime] done"

  block:
    ## cancellation
    notice "        cancellation"
    var jobs = newMailbox[Job]()
    info "[cancel] spawn"
    var runtime = Service.spawn(jobs)
    info "[cancel] cancel"
    cancel runtime
    info "[cancel] join"
    join runtime
    info "[cancel] done"

when isMainModule:
  main()
