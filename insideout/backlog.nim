import std/locks

import pkg/cps

import insideout/mailboxes
import insideout/runtimes

const LogBuffer = 32768  ## number of log messages to buffer

type
  Level* = enum
    lvlAll    = "All"     ## All levels active
    lvlDebug  = "Debug"   ## Debug level and above are active
    lvlInfo   = "Info"    ## Info level and above are active
    lvlNotice = "Notice"  ## Notice level and above are active
    lvlWarn   = "Warn"    ## Warn level and above are active
    lvlError  = "Error"   ## Error level and above are active
    lvlFatal  = "Fatal"   ## Fatal level and above are active
    lvlNone   = "None"    ## No levels active; nothing is logged

  LogMessage* = ref object
    level*: Level
    thread*: int
    message*: string

const logLevel* =  ## default log level
  when defined(logAll):
    lvlAll
  elif defined(logDebug) or defined(debug):
    lvlDebug
  elif defined(logInfo):
    lvlInfo
  elif defined(logNotice) or defined(release):
    lvlNotice
  elif defined(logWarn) or defined(danger):
    lvlWarn
  elif defined(logError):
    lvlError
  elif defined(logFatal):
    lvlFatal
  elif defined(logNone):
    lvlNone
  else:
    lvlInfo

when false:  # how could this be useful to the user?
  const
    LevelNames*: array[Level, string] = [
      "(ALL)", "DEBUG", "INFO", "NOTICE", "WARN", "ERROR", "FATAL", "(NONE)"
    ] ## Array of strings representing each logging level.

var L: Lock
initLock L
var C: Cond
initCond C

proc cooperate(c: Continuation): Continuation {.cpsMagic.} = c

proc emitLog(msg: sink LogMessage) =
  var ln = newStringOfCap(24 + msg.message.len)
  ln.add "#"
  ln.add $msg.thread
  ln.add " "
  ln.add $msg.level
  ln.add ": "
  ln.add msg.message
  stdmsg().writeLine(ln)

proc reader(queue: Mailbox[LogMessage]) {.cps: Continuation.} =
  let threadId = getThreadId()
  withLock L:
    signal C
    if logLevel <= lvlAll:
      emitLog LogMessage(thread: threadId, message: "hello backlog")
  while true:
    try:
      let msg = recv queue
      emitLog msg
    except IOError:
      discard
    except ValueError:  # queue unreadable
      break
    except OSError:
      raise Defect.newException "os error in backlog"
    cooperate()
  if logLevel <= lvlAll:
    emitLog LogMessage(thread: threadId, message: "goodbye backlog")

const QueueReader = whelp reader

# instantiate the log buffer
var queue = newMailbox[LogMessage](LogBuffer)

proc log*(level: Level; args: varargs[string, `$`]) =
  if level < logLevel: return
  var z = 0
  for arg in args.items:
    z += arg.len
  var s = newStringOfCap(z)
  for arg in args.items:
    s.add(arg)
  while true:
    try:
      queue.send:
        LogMessage(level: level, thread: getThreadId(), message: s)
      break
    except IOError:     # interrupted
      echo "INTERRUPT!"
      discard
    except ValueError:  # queue unwritable
      echo "UNWRITEABLE!"
      break

template debug*(args: varargs[untyped]) =
  if logLevel <= lvlDebug: log(lvlDebug, args)
template info*(args: varargs[untyped]) =
  if logLevel <= lvlInfo: log(lvlInfo, args)
template notice*(args: varargs[untyped]) =
  if logLevel <= lvlNotice: log(lvlNotice, args)
template warn*(args: varargs[untyped]) =
  if logLevel <= lvlWarn: log(lvlWarn, args)
template error*(args: varargs[untyped]) =
  if logLevel <= lvlError: log(lvlError, args)
template fatal*(args: varargs[untyped]) =
  if logLevel <= lvlFatal: log(lvlFatal, args)

# instantiate the reader
var runtime: Runtime[Continuation, LogMessage]
withLock L:
  runtime = spawn(QueueReader, queue)
  wait(C, L)
# the reader is running

type Grenade = object
proc `=destroy`(g: var Grenade) =
  deinitCond C
  deinitLock L
  disablePush queue         # drain the queue and close it
  join runtime              # wait for the reader to exit
var g {.used.}: Grenade     # pull the pin
