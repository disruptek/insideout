## Telegram example of Flow-Based Programming
##
## https://en.wikipedia.org/wiki/Flow-based_programming

##     In computer programming, flow-based programming (FBP) is a
##     programming paradigm that defines applications as networks of black
##     box processes, which exchange data across predefined connections
##     by message passing, where the connections are specified externally
##     to the processes. These black box processes can be reconnected
##     endlessly to form different applications without having to be
##     changed internally. FBP is thus naturally component-oriented.

##     FBP is a particular form of dataflow programming based on bounded
##     buffers, information packets with defined lifetimes, named ports,
##     and separate definition of connections.

## https://en.wikipedia.org/wiki/Flow-based_programming#%22Telegram_Problem%22
##

##     FBP components often form complementary pairs. This example
##     uses two such pairs. The problem described seems very simple as
##     described in words, but in fact is surprisingly difficult to
##     accomplish using conventional procedural logic. The task, called
##     the "Telegram Problem", originally described by Peter Naur, is to
##     write a program which accepts lines of text and generates output
##     lines containing as many words as possible, where the number of
##     characters in each line does not exceed a certain length. The words
##     may not be split and we assume no word is longer than the size of
##     the output lines. This is analogous to the word-wrapping problem in
##     text editors.

## this example exhibits the following features:
## - backpressure controls flow of data
## - lock-free mailboxes move data
## - components run in their own threads
## - component communication is asynchronous

import std/strutils
import pkg/cps

import insideout

type
  IP = ref string          ## Information Packet in Flow-Based Programming parlance
  Port = Mailbox[IP]       ## Port in Flow-Based Programming parlance

proc ip(s: string): IP =
  ## create a new Information Packet
  result = new string
  result[] = s

proc logAs(name: string): proc(text: varargs[string, `$`]) =
  ## create a debugging function to output thread/name
  result =
    proc(text: varargs[string, `$`]) =
      var output: string
      for s in text.items: output &= s
      debugEcho "$# $#: $#" % [$getThreadId(), name, output]

proc reader(filename: string; output: Port) {.cps: Continuation.} =
  ## reads `filename` line by line and sends each line as an IP to `output`.
  let debug = logAs"reader"
  debug "(start)"
  let stream = open(filename, fmRead)
  for line in stream.lines:
    debug "-> ", line
    output.send(ip line)     # blocks if the port is full
  close stream
  disablePush output         # close the port to signify end of data
  debug "(stop)"

proc decomposer(input: Port; output: Port) {.cps: Continuation.} =
  ## splits each IP from `input` into words sends each as an IP to `output`.
  let debug = logAs"decomposer"
  debug "(start)"
  while true:
    try:
      var ip = input.recv()     # blocks if the port is empty
      debug "<- ", ip[]
      for word in ip[].split:
        debug "-> ", word
        output.send(ip word)    # blocks if the port is full
    except ValueError:          # input port is closed
      break
  disablePush output            # close the port to signify end of data
  debug "(stop)"

proc recomposer(input: Port; output: Port; size: Positive) {.cps: Continuation.} =
  ## receives words of IP from `input` and reassembles them into lines of
  ## <= `size` characters, sending each line as an IP to `output` port.
  let debug = logAs"recomposer"
  debug "(start)"
  var line: string
  while true:
    try:
      var ip = input.recv()     # blocks if the port is empty
      debug "<- ", ip[]
      if line.len + ip[].len + 1 > size:
        debug "-> ", line
        output.send(ip line)    # blocks if the port is full
        line = ""
      else:
        if line.len > 0:
          line.add " "
        line.add ip[]
    except ValueError:          # input port is closed
      break
  if line != "":
    debug "-> ", line
    output.send(ip line)        # blocks if the port is full
  disablePush output            # close the port to signify end of data
  debug "(stop)"

proc writer(input: Port; filename: string) {.cps: Continuation.} =
  ## receives lines of IP from `input` and writes them to `filename`.
  let debug = logAs"writer"
  debug "(start)"
  let stream = open(filename, fmWrite)
  while true:
    try:
      var ip = input.recv()     # blocks if the port is empty
      debug "<- ", ip[]
      stream.writeLine ip[]
    except ValueError:          # input port is closed
      break
  close stream
  disablePop input              # close the port to signify end of data
  debug "(stop)"

proc network(components: varargs[Continuation]): auto =
  ## spawn each component and return a running thread pool
  result = newPool ContinuationRunner
  for component in components.items:
    # create a mailbox to deliver the component to the thread for dispatch
    var transport = newMailbox[Continuation]()
    # put the component into the mailbox so the thread can receive it
    transport.send(component)
    # spawn a thread to run the component, using the transport as input
    result.spawn(ContinuationRunner, transport)

proc wrap(inputFile: string; outputFile: string; size: Positive = 80) =
  ## perform word-wrapping on a multi-line `inputFile`, writing the
  ## result to `outputFile`. `size` is the maximum number of characters
  ## per line.
  let debug = logAs"wrap"
  # create ports with backpressure
  let rseq_dc = newMailbox[IP](1)             # one input line at a time
  let dc_rc = newMailbox[IP](30)              # many words at a time
  let rc_wseq = newMailbox[IP](1)             # one output line at a time
  debug "setting up network"
  block:
    # setup and run the network in a thread pool
    var pool = network(whelp reader(filename = inputFile, output = rseq_dc),
                       whelp decomposer(input = rseq_dc, output = dc_rc),
                       whelp recomposer(input = dc_rc, output = rc_wseq,
                                        size = size),
                       whelp writer(input = rc_wseq, filename = outputFile))
    debug "network is running"
  debug "network is complete"

when isMainModule:
  let input = "data/input.txt"
  let output = "data/output.txt"
  proc dumpFile(name: string) =
    ## dump the contents of `name` to the debug output
    debugEcho "\n\t$#:\n" % [name]
    for line in name.lines:
      debugEcho line
  # perform word-wrapping on input file; deliver to output file
  wrap(input, output, size = 40)
  dumpFile input
  dumpFile output
