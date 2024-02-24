import std/locks
import std/posix
import std/strformat

import pkg/cps

import insideout/mailboxes
import insideout/runtimes
import insideout/threads
import insideout/times

const backlogBuffer {.strdefine.} = 64*1024  ## number of log messages to buffer
const backlogFile {.strdefine.} = "backlog.txt"
const backlogPerms = S_IRUSR or S_IWUSR
const backlogModes = O_CREAT or O_WRONLY or O_APPEND or O_NOATIME
const backlogCoarse {.booldefine.} = defined(danger)

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
    level: Level
    thread: int
    monoTime: TimeSpec
    realTime: TimeSpec
    threadTime: TimeSpec
    message: string

  Fd = cint  ## convenience for file descriptor, uh, description

const logLevel* =  ## default log level
  when defined(logNone):
    lvlNone
  elif defined(logFatal):
    lvlFatal
  elif defined(logError):
    lvlError
  elif defined(logWarn):
    lvlWarn
  elif defined(logNotice):
    lvlNotice
  elif defined(logInfo):
    lvlInfo
  elif defined(logDebug):
    lvlDebug
  elif defined(logAll):
    lvlAll
  elif defined(danger):
    lvlWarn
  elif defined(release):
    lvlNotice
  elif defined(debug):
    lvlDebug
  else:
    lvlInfo

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

when false:  # how could this be useful to the user?
  const
    LevelNames*: array[Level, string] = [
      "(ALL)", "DEBUG", "INFO", "NOTICE", "WARN", "ERROR", "FATAL", "(NONE)"
    ] ## Array of strings representing each logging level.

proc log*(level: Level; args: varargs[string, `$`])

var L: Lock
initLock L
var C: Cond
initCond C

proc cooperate(c: Continuation): Continuation {.cpsMagic.} = c

var n: int

when backlogCoarse:
  # faster but less accurate
  let rtClock = CLOCK_REALTIME_COARSE
  let mtClock = CLOCK_MONOTONIC_COARSE
else:
  const rtClock = CLOCK_REALTIME
  const mtClock = CLOCK_MONOTONIC

proc stringMessage(level: Level; message: string; thread: int): LogMessage =
  result = LogMessage(level: level, thread: thread, message: message)
  discard clock_gettime(mtClock, result.monoTime)
  discard clock_gettime(rtClock, result.realTime)
  discard clock_gettime(CLOCK_THREAD_CPUTIME_ID, result.threadTime)

proc createMessage(level: Level; args: varargs[string, `$`]): LogMessage =
  var z = 0
  for arg in args.items:
    z += arg.len
  var s = newStringOfCap(z)
  for arg in args.items:
    s.add(arg)
  result = stringMessage(level, s, getThreadId())

proc emitLog(fd: Fd; msg: sink LogMessage) =
  inc n
  var ln = newStringOfCap(48 + msg.message.len)
  #const ft = "yyyy-MM-dd\'T\'HH:mm:ss\'.\'fff \'#\'"
  #ln.add msg.time.format(ft)
  ln.add:
    &"{msg.level:<6s} {n:>3d} #{msg.thread:<5d} {msg.monoTime} {msg.message}\n"
  block:
    let ln = ln.cstring
    var wrote = 0
    while wrote < ln.len:
      let more = write(fd, cast[pointer](cast[int](ln) + wrote), ln.len - wrote)
      if more == -1:
        error "backlog write failed with " & $strerror(errno)
      else:
        wrote += more

proc reader(queue: Mailbox[LogMessage]) {.cps: Continuation.} =
  # see if we need to crash right away...
  var fd = open(backlogFile, backlogModes, backlogPerms)
  if fd == -1:
    stdmsg().writeLine(backlogFile & ": " & $strerror(errno))
    quit 1
    return

  let threadId = getThreadId()
  withLock L:
    signal C      # let the parent continue

  when logLevel <= lvlNone:
    fd.emitLog lvlNone.stringMessage("hello backlog", thread = threadId)

  discard pthread_setname_np(pthread_self(), "io: backlog")

  while true:
    var msg: LogMessage
    case queue.tryRecv(msg)
    of Received:
      fd.emitLog(move msg)
    elif not queue.waitForPoppable():
      break
    cooperate()

  when logLevel <= lvlNone:
    fd.emitLog lvlNone.stringMessage("goodbye backlog", thread = threadId)

  discard close fd

const QueueReader = whelp reader

# instantiate the log buffer
var queue = newMailbox[LogMessage](backlogBuffer)

proc log*(level: Level; args: varargs[string, `$`]) {.raises: [].} =
  if level < logLevel: return
  var message = createMessage(level, args)
  while true:
    let r = queue.trySend(message)
    case r
    of Unwritable, Delivered:
      break
    elif not queue.waitForPushable():
      break

# stuff the queue to identify the parent thread
log(lvlNone, "program began")

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
  closeWrite queue          # drain the queue and close it
  halt runtime              # signal the reader to exit
  join runtime              # wait for the reader to exit
var g {.used.}: Grenade     # pull the pin
