import std/atomics
#import std/macros
import std/posix

import pkg/cps
import pkg/trees/avl

import insideout/spec
import insideout/times
import insideout/importer
import insideout/atomic/refs
export refs

macro signalfdh(n: untyped): untyped = importer(n, newLit"<sys/signalfd.h>")
macro eventfdh(n: untyped): untyped = importer(n, newLit"<sys/eventfd.h>")
macro epollh(n: untyped): untyped = importer(n, newLit"<sys/epoll.h>")
macro epollh(s: untyped; n: untyped): untyped =
  importer(n, newLit"<sys/epoll.h>", s)

let EPOLL_CTL_ADD {.epollh.}: cint
let EPOLL_CTL_MOD {.epollh.}: cint
let EPOLL_CTL_DEL {.epollh.}: cint

type
  PollError* = object of OSError

  Id* = distinct culonglong
  Fd* = distinct cint

  EventQueueObj = object
    registry: Registry
    watchers: Watchers
    interrupt: Fd
    interruptId: Id
    interest: Fd
    nextId: Atomic[uint64]

  EventQueue* = AtomicRef[EventQueueObj]

  Registry = AVLTree[Id, Record]
  Watchers = AVLTree[Fd, Registry]

  Event = enum
    Read
    Write
    Error
    Hangup
    NoPeer
    OneShot
    Level
    Edge
    Priority
    Exclusive
    Wakeup

  epoll_events = enum
    EPOLLIN             = 0x001      ## There is data to read.
    EPOLLPRI            = 0x002      ## There is urgent data to read.
    EPOLLOUT            = 0x004      ## Writing now will not block.
    EPOLLERR            = 0x008      ## Error condition.
    EPOLLHUP            = 0x010      ## Hung up.
    EPOLLRDNORM         = 0x040      ## Normal data may be read.
    EPOLLRDBAND         = 0x080      ## Priority data may be read.
    EPOLLWRNORM         = 0x100      ## Writing now will not block.
    EPOLLWRBAND         = 0x200      ## Priority data may be written.
    EPOLLMSG            = 0x400      ## Input message is available.
    EPOLLRDHUP          = 0x2000     ## Socket peer closed connection.
    EPOLLEXCLUSIVE      = 1 shl 28   ## Sets exclusive wakeup mode.
    EPOLLWAKEUP         = 1 shl 29   ## Wakes up the blocked system call.
    EPOLLONESHOT        = 1 shl 30   ## Sets one-shot behavior.
    EPOLLET             = 1 shl 31   ## Enables edge-triggered events.

  epoll_event* {.epollh: "struct epoll_event".} = object
    events: cuint
    data: epoll_data

  RecordObj = object
    c: Continuation
    id: Id
    fd: Fd
    mask: cuint
    events: set[Event]
  Record = ref RecordObj

  epoll_data {.epollh: "union epoll_data".} = object
    u64: uint64

let SFD_NONBLOCK* {.signalfdh.}: cint
let SFD_CLOEXEC* {.signalfdh.}: cint
proc signalfd*(fd: cint; mask: ptr Sigset; flags: cint): cint {.signalfdh.}

proc `<`(a, b: Fd): bool {.borrow, used.}
proc `==`(a, b: Fd): bool {.borrow, used.}
proc close(fd: Fd): cint {.borrow, used.}
proc `<`(a, b: Id): bool {.borrow, used.}
proc `==`(a, b: Id): bool {.borrow, used.}

const
  invalidId: Id = 0.Id
  invalidFd*: Fd = -1.Fd

proc `=copy`*[T](dest: var EventQueueObj; src: EventQueueObj) {.error.}

converter toCint(event: epoll_events): uint32 = event.ord.uint32

proc eventfd(count: culonglong; flags: cint): Fd {.noconv, eventfdh.}

proc epoll_create(flags: cint): Fd {.noconv, epollh: "epoll_create1".}

proc epoll_ctl(epfd: cint; op: cint; fd: cint; event: ptr epoll_event): cint
  {.noconv, epollh.}

proc epoll_wait(epfd: cint; events: ptr epoll_event;
                maxevents: cint; timeout: cint): cint {.noconv, epollh.}

proc epoll_pwait2(epfd: cint; events: ptr epoll_event; maxevents: cint;
                  timeout: ptr TimeSpec; sigmask: ptr Sigset): cint {.noconv, epollh.}

proc handleErrno() =
  case errno
  of EBADF:
    raise Defect.newException "bad file descriptor"
  of EFAULT:
    raise Defect.newException "bad address"
  of EINTR:
    discard
  of EINVAL:
    raise Defect.newException "eventqueue uninitialized"
  else:
    raise Defect.newException "epoll_wait: " & $errno & " " & $strerror(errno)

proc checkPoll(e: cint): cint {.discardable.} =
  if e == -1:
    handleErrno()
    0
  else:
    e

proc destroy[K, V](tree: var AVLTree[K, V]) =
  while tree.len > 0:
    tree.popMax

proc delRegistry(eq: var EventQueueObj; fd: Fd) =
  if fd in eq.watchers:
    checkPoll epoll_ctl(eq.interest.cint, EPOLL_CTL_DEL, fd.cint, nil)
    var registry = eq.watchers.pop(fd)
    destroy registry

proc delRegistry(eq: var EventQueueObj; record: Record) =
  if not eq.registry.remove(record.id):
    raise Defect.newException "event not found"
  if record.fd in eq.watchers:
    if not eq.watchers[record.fd].remove(record.id):
      raise Defect.newException "event not found"
    if eq.watchers[record.fd].len == 0:
      eq.delRegistry record.fd
    else:
      raise Defect.newException "interest mod not impl"

proc destroy(fd: var Fd) =
  while EINTR == close fd:
    discard
  fd = invalidFd

proc `=destroy`*(eq: var EventQueueObj) =
  # close epollfd
  destroy eq.interest
  # close interrupt eventfd
  destroy eq.interrupt
  # clear out the watchers quickly
  reset eq.watchers
  # destroy queued continuations in reverse order
  while eq.registry.len > 0:
    let (id, record) = eq.registry.popMax()
    eq.delRegistry record
  for key, value in eq.fieldPairs:
    reset value

proc receive(c: Continuation; events: set[Event]): Continuation {.cpsMagic.} =
  echo events
  result = c

proc composeEvent(eq: var EventQueueObj; events: set[Event]): epoll_event =
  var id = fetchAdd(eq.nextId, 1, order = moAcquireRelease)
  # defaults; ERROR and HANGUP are implicit
  result.events = EPOLLPRI or EPOLLERR or EPOLLHUP
  # event types
  if Read in events:
    result.events = result.events or EPOLLIN or EPOLLRDHUP
  if Write in events:
    result.events = result.events or EPOLLOUT
  if Level in events:
    raise Defect.newException "not implemented"
  elif Edge in events:
    result.events = result.events or EPOLLET
  else:
    raise Defect.newException "specify Edge or Level"
  result.data.u64 = id

template id(event: epoll_event): Id = Id(event.data.u64)

proc addRegistry(eq: var EventQueueObj; record: Record) =
  eq.registry.insert(record.id, record)
  if record.fd in eq.watchers:
    eq.watchers[record.fd].insert(record.id, record)
  else:
    var registry: Registry
    registry.insert(record.id, record)
    eq.watchers[record.fd] = registry

proc register[T](eq: var EventQueueObj; c: var T; fd: Fd;
                 events: set[Event]): Id =
  var ev = composeEvent(eq, events)
  var record =
    Record(c: c, id: ev.id, fd: fd, mask: ev.events, events: events)
  try:
    eq.addRegistry record
    checkPoll epoll_ctl(eq.interest.cint, EPOLL_CTL_ADD, fd.cint, addr ev)
    result = ev.id
  except CatchableError as e:
    eq.delRegistry record
    raise

proc unregister(eq: var EventQueueObj; id: Id) =
  if id in eq.registry:
    eq.delRegistry eq.registry[id]

proc surrender(c: sink Continuation; eq: var EventQueueObj;
               id: Id): Continuation {.cpsMagic.} =
  unregister(eq, id)
  result = c

proc waitForInterrupt(c: sink Continuation): Continuation {.cpsMagic.} =
  result = nil

proc interruptor(eq: EventQueue) {.cps: Continuation.} =
  var i = 0
  while true:
    inc i
    echo "interrupt " & $i
    waitForInterrupt()

proc init*(eq: var EventQueueObj; interruptor: sink Continuation) =
  ## initialize the eventqueue with the given interruptor
  eq.interest = epoll_create(O_CLOEXEC)
  eq.interrupt = eventfd(0, O_NONBLOCK or O_CLOEXEC)
  eq.interruptId = register(eq, interruptor, eq.interrupt, {Read, Edge})
  assert eq.interruptId in eq.registry

proc init*(eq: var EventQueue) =
  if eq.isNil:
    new eq
    var c = whelp interruptor(eq)
    eq[].init(c)

proc toSet(event: epoll_event): set[Event] =
  if 0 != (event.events and EPOLLIN.ord):
    result.incl Read
  if 0 != (event.events and EPOLLOUT.ord):
    result.incl Write
  if 0 != (event.events and EPOLLPRI.ord):
    result.incl Priority
  if 0 != (event.events and EPOLLRDHUP.ord):
    result.incl Hangup
  if 0 != (event.events and EPOLLERR.ord):
    result.incl Error
  if 0 != (event.events and EPOLLHUP.ord):
    result.incl Hangup

proc runEvent(eq: var EventQueueObj; event: var epoll_event) {.deprecated.} =
  let record =
    try:
      eq.registry[event.id]
    except KeyError:
      raise Defect.newException "lost record"
      nil
  # XXX
  var events = event.toSet
  var x = trampoline(move record.c)
  record.c = move x

template maybeInit(eq: var EventQueue): untyped =
  if eq.isNil:
    init eq

proc wait*[T](eq: var EventQueue; events: var T;
           timeout: ptr TimeSpec; mask: ptr Sigset): cint =
  maybeInit eq
  let quantity: cint = cint sizeof(events) div sizeof(epoll_event)
  let eventsP = cast[ptr epoll_event](addr events)
  result = epoll_pwait2(eq[].interest.cint, eventsP, quantity, timeout, mask)

proc wait*[T](eq: var EventQueue; events: var T; timeout: float): cint =
  var ts = timeout.toTimeSpec
  result = wait(eq, events, timeout = addr ts, nil)

proc wait*[T](eq: var EventQueue; events: var T): cint =
  result = wait(eq, events, nil, nil)

proc wait*(eq: var EventQueue): cint =
  var events: array[1, epoll_event]
  result = wait(eq, events)

proc run*[T](eq: EventQueue; events: var T; quantity: cint) =
  let maximum: cint = cint sizeof(events) div sizeof(epoll_event)
  if quantity > maximum:
    raise Defect.newException "insufficient event buffer size"
  else:
    var i = quantity
    while i > 0:
      dec i
      eq[].runEvent(events[i])  # XXX: temporary

converter toFd*(s: SocketHandle): Fd = s.Fd
converter toCint*(fd: Fd): cint = fd.cint
converter toCint*(id: Id): cint = id.cint
