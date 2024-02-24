import std/atomics
import std/posix

import pkg/cps
import pkg/trees/avl

import insideout/times
import insideout/importer
import insideout/atomic/refs
export refs

macro timerfdh(n: untyped): untyped = importer(n, newLit"<sys/timerfd.h>")
macro timerfdh(s: untyped; n: untyped): untyped =
  importer(n, newLit"<sys/timerfd.h>", s)
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
    interest: Fd
    registry: Registry
    watchers: Watchers
    interrupt: Fd
    interruptId: Id
    nextId: Atomic[uint64]

  EventQueue* = AtomicRef[EventQueueObj]

  Registry = AVLTree[Id, Record]
  Watchers = AVLTree[Fd, Registry]

  Event = enum
    Read
    Write
    Error
    HangUp
    NoPeer
    OneShot
    Level
    Edge
    Priority
    Exclusive
    WakeUp
    Message

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

const
  invalidId: Id = 0.Id
  invalidFd*: Fd = -1.Fd
  AllEvents = {Read, Write, Error, HangUp, NoPeer, Edge, Priority, Exclusive,
               WakeUp, Message}

type
  itimerspec {.timerfdh: "struct itimerspec".} = object
    it_interval: TimeSpec
    it_value: TimeSpec

proc timerfd_create(clock: ClockId; flags: cint): Fd {.timerfdh.}
proc timerfd_settime(fd: Fd; flags: cint; new_value: ptr itimerspec;
                     old_value: ptr itimerspec): cint {.timerfdh.}
proc timerfd_gettime(fd: Fd; curr_value: ptr itimerspec): cint {.timerfdh.}
let TFD_NONBLOCK* {.timerfdh.}: cint
let TFD_CLOEXEC* {.timerfdh.}: cint
let TFD_TIMER_ABSTIME* {.timerfdh.}: cint
let TFD_TIMER_CANCEL_ON_SET* {.timerfdh.}: cint

let SFD_NONBLOCK* {.signalfdh.}: cint
let SFD_CLOEXEC* {.signalfdh.}: cint
proc signalfd*(fd: Fd; mask: ptr Sigset; flags: cint): Fd {.signalfdh.}

proc `<`(a, b: Id): bool {.borrow, used.}
proc `==`(a, b: Id): bool {.borrow, used.}
proc `<`(a, b: Fd): bool {.borrow, used.}
proc `==`(a, b: Fd): bool {.borrow, used.}

proc close*(fd: var Fd) =
  if fd != invalidFd:
    while EINTR == posix.close(fd.cint):
      discard
    fd = invalidFd

proc destroy[K, V](tree: var AVLTree[K, V]) =
  while tree.len > 0:
    tree.popMax

proc deinit(eq: var EventQueueObj) =
  # close epollfd
  close eq.interest
  # close interrupt eventfd
  close eq.interrupt
  # clear out the watchers quickly
  reset eq.watchers
  # destroy queued continuations in reverse order
  destroy eq.registry
  for key, value in eq.fieldPairs:
    when value isnot Fd:
      reset value

proc `=destroy`(eq: var EventQueueObj) =
  deinit eq

proc deinit*(eq: var EventQueue) =
  ## deinitialize the eventqueue
  if not eq.isNil:
    deinit eq[]

template withNewEventQueue*(name: untyped; body: untyped): untyped =
  ## create and initialize an eventqueue named `name` and run
  ## `body` with it, deinitializing it at close of scope.
  var name {.inject.}: EventQueue
  init name
  try:
    body
  finally:
    deinit name

proc `=copy`*[T](dest: var EventQueueObj; src: EventQueueObj) {.error.}

converter toCint(event: epoll_events): uint32 = event.ord.uint32

proc eventfd(count: culonglong; flags: cint): Fd {.noconv, eventfdh.}

proc epoll_create(flags: cint): Fd {.noconv, epollh: "epoll_create1".}

proc epoll_ctl(epfd: Fd; op: cint; fd: Fd; event: ptr epoll_event): cint
  {.noconv, epollh.}

proc epoll_wait(epfd: cint; events: ptr epoll_event;
                maxevents: cint; timeout: cint): cint {.noconv, epollh.}

proc epoll_pwait2(epfd: cint; events: ptr epoll_event; maxevents: cint;
                  timeout: ptr TimeSpec; sigmask: ptr Sigset): cint
                 {.noconv, epollh.}

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

proc checkErr[T](err: T): T {.discardable.} =
  if err.cint == -1:
    raise OSError.newException $strerror(errno)
  else:
    result = err

proc delRegistry(eq: var EventQueueObj; fd: Fd) =
  if fd in eq.watchers:
    checkErr epoll_ctl(eq.interest, EPOLL_CTL_DEL, fd, nil)
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

proc composeEvent(eq: var EventQueueObj; events: set[Event]): epoll_event =
  assert eq.interest != invalidFd
  var id = fetchAdd(eq.nextId, 1, order = moAcquireRelease)
  # event types
  if true or HangUp in events:    # defaults to `on`
    result.events = result.events or EPOLLHUP
  if true or Error in events:     # defaults to `on`
    result.events = result.events or EPOLLERR
  if true or Priority in events:  # defaults to `on`
    result.events = result.events or EPOLLPRI
  if Read in events:
    result.events = result.events or EPOLLIN or EPOLLRDHUP
  if Write in events:
    result.events = result.events or EPOLLOUT
  if OneShot in events:
    result.events = result.events or EPOLLONESHOT
  if NoPeer in events:
    result.events = result.events or EPOLLRDHUP
  if WakeUp in events:
    result.events = result.events or EPOLLWAKEUP
  if Exclusive in events:
    result.events = result.events or EPOLLEXCLUSIVE
  if Message in events:
    result.events = result.events or EPOLLMSG
  if WakeUp in events:
    result.events = result.events or EPOLLWAKEUP
  if Level in events:
    raise Defect.newException "not implemented"
  elif Edge in events:
    result.events = result.events or EPOLLET
  else:
    raise Defect.newException "specify Edge or Level"
  result.data.u64 = id

template id(event: epoll_event): Id = Id(event.data.u64)

proc addRegistry(eq: var EventQueueObj; record: Record) =
  assert eq.interest != invalidFd
  eq.registry.insert(record.id, record)
  if record.fd in eq.watchers:
    eq.watchers[record.fd].insert(record.id, record)
  else:
    var registry: Registry
    registry.insert(record.id, record)
    eq.watchers[record.fd] = registry

proc register(eq: var EventQueueObj; c: sink Continuation;
              fd: Fd; events: set[Event]): Id =
  assert eq.interest != invalidFd
  var ev = composeEvent(eq, events)
  var record =
    Record(c: c, id: ev.id, fd: fd, mask: ev.events, events: events)
  try:
    eq.addRegistry record
    checkErr epoll_ctl(eq.interest, EPOLL_CTL_ADD, fd, addr ev)
    result = ev.id
  except CatchableError as e:
    eq.delRegistry record
    raise

proc register*(eq: EventQueue; c: sink Continuation;
               fd: Fd; events: set[Event]): Id =
  assert not eq.isNil
  register(eq[], c, fd, events)

proc unregister(eq: var EventQueueObj; id: Id) =
  assert eq.interest != invalidFd
  if id in eq.registry:
    eq.delRegistry eq.registry[id]

proc surrender(c: sink Continuation; eq: EventQueue;
               id: Id): Continuation {.cpsMagic.} =
  unregister(eq[], id)
  result = c

proc waitForInterrupt(c: sink Continuation): Continuation {.cpsMagic.} =
  result = nil

proc interruptor(eq: EventQueue) {.cps: Continuation.} =
  var i = 0
  while true:
    inc i
    echo "interrupt " & $i
    waitForInterrupt()

proc init(eq: var EventQueueObj; interruptor: sink Continuation) =
  ## initialize the eventqueue with the given interruptor
  eq.interest = checkErr epoll_create(O_CLOEXEC)
  assert eq.interest != invalidFd
  when false:
    eq.interrupt = eventfd(0, O_NONBLOCK or O_CLOEXEC)
    eq.interruptId = register(eq, interruptor, eq.interrupt, {Read, Edge})
    assert eq.interruptId in eq.registry
  else:
    eq.interrupt = invalidFd

proc init*(eq: var EventQueue) =
  if eq.isNil:
    new eq
    when false:
      var c = whelp interruptor(eq)
      eq[].init(c)
    else:
      eq[].init(nil)
  assert eq[].interest != invalidFd

proc toSet(event: epoll_event): set[Event] =
  ## some liberties taken here for the composition reasons
  if 0 != (event.events and EPOLLIN.ord):
    result.incl Read
  if 0 != (event.events and (EPOLLRDNORM.ord or EPOLLRDBAND.ord)):
    result.incl Read
  if 0 != (event.events and EPOLLOUT.ord):
    result.incl Write
  if 0 != (event.events and (EPOLLWRNORM.ord or EPOLLWRBAND.ord)):
    result.incl Write
  if 0 != (event.events and (EPOLLRDBAND.ord or EPOLLWRBAND.ord)):
    result.incl Priority
  if 0 != (event.events and EPOLLPRI.ord):
    result.incl Priority
  if 0 != (event.events and EPOLLRDHUP.ord):
    result.incl NoPeer
  if 0 != (event.events and EPOLLERR.ord):
    result.incl Error
  if 0 != (event.events and EPOLLHUP.ord):
    result.incl HangUp
  if 0 != (event.events and EPOLLMSG.ord):
    result.incl Message
  if 0 != (event.events and EPOLLEXCLUSIVE.ord):
    result.incl Exclusive
  if 0 != (event.events and EPOLLWAKEUP.ord):
    result.incl WakeUp
  if 0 != (event.events and EPOLLET.ord):
    result.incl Edge

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
  assert eq[].interest != invalidFd

proc pruneOneShots(eq: var EventQueueObj; events: var openArray[epoll_event];
                   quantity: cint) =
  ## remove any one-shot events from the registry
  var i = quantity
  while i > 0:
    dec i
    let id = events[i].id
    if id notin eq.registry:
      raise Defect.newException "lost record"
    else:
      let record = eq.registry[id]
      if OneShot in record.events:
        eq.delRegistry record

proc pruneOneShots*(eq: EventQueue; events: var openArray[epoll_event];
                    quantity: cint) =
  ## remove any one-shot events from the registry
  eq[].pruneOneShots(events, quantity)

proc wait*(eq: var EventQueue; events: var openArray[epoll_event];
           timeout: ptr TimeSpec; mask: ptr Sigset): cint =
  ## wait up to `timeout` for `events` under signal mask `mask`
  maybeInit eq
  result = epoll_pwait2(eq[].interest.cint, cast[ptr epoll_event](addr events[0]),
                        events.len.cint, timeout, mask)

proc wait*(eq: var EventQueue; events: var openArray[epoll_event];
           timeout: float): cint =
  ## wait up to `timeout` seconds for `events`
  var ts = timeout.toTimeSpec
  result = wait(eq, events, timeout = addr ts, nil)

proc wait*(eq: var EventQueue; events: var openArray[epoll_event]): cint =
  ## wait for events
  result = wait(eq, events, nil, nil)

proc wait*(eq: var EventQueue): cint =
  ## wait for the next event and discard it
  var events: array[1, epoll_event]
  result = wait(eq, events)

proc run*(eq: EventQueue; events: var openArray[epoll_event]; quantity: cint) =
  if quantity > events.len:
    raise Defect.newException "insufficient event buffer size"
  elif quantity > 0:
    var i = quantity
    while i > 0:
      dec i
      eq[].runEvent(events[i])  # XXX: temporary

proc suspend(c: sink Continuation; eq: EventQueue;
             fd: Fd; events: set[Event]): Continuation {.cpsMagic.} =
  discard register(eq, c, fd, events)

proc register*(eq: EventQueue; fd: Fd; events: set[Event] = AllEvents): Id {.cps: Continuation.} =
  assert eq[].interest != invalidFd
  assert fd != invalidFd
  eq.suspend(fd, {Edge} + events)

proc sleep*(eq: EventQueue; timeout: float) {.cps: Continuation.} =
  ## sleep for `timeout` seconds
  var fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK or TFD_CLOEXEC).Fd
  var it: itimerspec
  it.it_value = timeout.toTimeSpec
  checkErr timerfd_settime(fd, 0, addr it, nil)
  discard eq.register(fd, {Read, OneShot})

converter toFd*(s: SocketHandle): Fd = s.Fd
converter toCint*(fd: Fd): cint = fd.cint
converter toCint*(id: Id): cint = id.cint
