# telegram example of flow-based programming
import std/strutils
import pkg/cps

import insideout

type
  IP = ref string
  Port = UnboundedFifo[IP]

proc ip(s: string): IP =
  result = new string
  result[] = s

proc reader(filename: string; output: Port) {.cps: Continuation.} =
  debugEcho getThreadId(), " reader starting"
  let stream = open(filename, fmRead)
  for line in stream.lines:
    debugEcho "read> ", line
    try:
      output.send(ip line)
    except ValueError:
      break
  close stream
  disablePush output
  debugEcho getThreadId(), " reader stopping"

proc decomposer(input: Port; output: Port) {.cps: Continuation.} =
  debugEcho getThreadId(), " decomposer starting"
  while true:
    try:
      var ip = input.recv()
      for word in ip[].split:
        debugEcho "dc-> ", word
        output.send(ip word)
    except ValueError:
      break
  disablePush output
  debugEcho getThreadId(), " decomposer stopping"

proc recomposer(input: Port; output: Port; size: Positive) {.cps: Continuation.} =
  debugEcho getThreadId(), " recomposer starting"
  var line: string
  while true:
    try:
      var ip = input.recv()
      debugEcho "rc-> ", ip[]
      if line.len + ip[].len + 1 > size:
        output.send(ip line)
        line = ""
      else:
        if line.len > 0:
          line.add " "
        line.add ip[]
      debugEcho "rc=> ", line
    except ValueError:
      break
  disablePush output
  debugEcho getThreadId(), " recomposer stopping"

proc writer(filename: string; input: Port) {.cps: Continuation.} =
  debugEcho getThreadId(), " writer starting"
  let stream = open(filename, fmWrite)
  while true:
    try:
      var ip = input.recv()
      debugEcho "write> ", ip[]
      stream.writeLine ip[]
    except ValueError:
      break
  close stream
  debugEcho getThreadId(), " writer stopping"

proc network(pool: var Pool; components: varargs[Continuation]) =
  for component in components.items:
    var transport = newUnboundedFifo[Continuation]()
    transport.send(component)
    pool.spawn(ContinuationRunner, transport)

proc main(input: string; output: string; size: Positive = 80) =
  # create ports
  let rseq_dc = newMailbox[IP]()
  let dc_rc = newMailbox[IP]()
  let rc_wseq = newMailbox[IP]()
  # setup network
  var pool = newPool ContinuationRunner
  pool.network(whelp reader(input, rseq_dc),
               whelp writer(output, rc_wseq),
               whelp decomposer(rseq_dc, dc_rc),
               whelp recomposer(dc_rc, rc_wseq, size))
  debugEcho "network running"
  # drain network
  for component in pool.mitems:
    join component
  debugEcho "network complete"

main("data/input.txt", "data/output.txt", size = 60)
