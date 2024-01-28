import std/os
import std/posix

import pkg/cps

import insideout

type
  Reader = ref object of Continuation ## \
    ## this is an example "server" that will consume messages from
    ## a mailbox; what we're trying to demonstrate here is that the
    ## continuation environment can store arbitrary data that persists
    ## between messages
    receiver: int
    total: int

  Message = ref object ## \
    ## this is an example "message" that will be sent to the service; all
    ## we're demonstrating here is that we can pass arbitrary references
    ## between threads

    sender: int
    text: string

proc newMessage(text: string): Message =
  ## create a new Message (a ref object)
  Message(sender: getThreadId(), text: text)

proc initialize(c: Reader): Reader {.cpsMagic.} =
  c.receiver = getThreadId()
  result = c

proc updateTotal(c: Reader; message: Message): int {.cpsVoodoo.} =
  c.total += len message.text
  result = c.total

proc receiver(c: Reader): int {.cpsVoodoo.} =
  c.receiver

proc reader(queue: UnboundedFifo[Message]) {.cps: Reader.} =
  initialize()
  while true:
    var msg = recv queue
    echo receiver(), "> received message from ", msg.sender, ": ", msg.text
    echo receiver(), "> total bytes received: ", updateTotal(msg)

const
  Receiver = whelp reader

proc main() =
  var messages = newMailbox[Message]()
  var runtime = spawn(Receiver, messages)
  block:
    messages.send:
      newMessage"hello, world!"
    sleep 100
  stop runtime
  sleep 500
  cancel runtime

main()
