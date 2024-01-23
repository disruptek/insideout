# TODO:
# epoll_pwait +/- timeout
import std/selectors
import std/monotimes
import std/posix

import pkg/cps

import pkg/trees/avl

type
  Id* = distinct cint
  Fd* = distinct cint

  EventQueue* = object
    selector: Selector[Fd]
    registry: AVLTree[Id, ptr EpollData]
    interrupt: Fd
    interruptId: Id
    interest: Fd
    lastId: Id

  EpollData = object
    c: Continuation
    fd: Fd
    id: Id
    pad: uint64

  State = enum
    Newborn
    Pending
    Running

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

  epoll_ctl_op = enum
    EPOLL_CTL_ADD = 1
    EPOLL_CTL_DEL = 2
    EPOLL_CTL_MOD = 3

  epoll_event {.header: "<sys/epoll.h>", completeStruct, importc.} = object
    events: cuint
    data: ptr epoll_data_t

  epoll_data_t {.header: "<sys/epoll.h>", completeStruct, importc.} = object
    p: pointer
    fd: cint
    u32: cuint
    u64: culonglong

static:
  assert sizeof(epoll_data_t) == sizeof(EpollData)

proc `<`(a, b: Fd): bool {.borrow, used.}
proc `==`(a, b: Fd): bool {.borrow, used.}
proc close(fd: Fd): cint {.borrow, used.}
proc `<`(a, b: Id): bool {.borrow, used.}
proc `==`(a, b: Id): bool {.borrow, used.}

const
  invalidId: Id = 0.Id
  invalidFd: Fd = -1.Fd

var eq {.threadvar.}: EventQueue

proc state(eq: EventQueue): State =
  ## compute the state of the event queue
  if eq.selector.isNil:
    Newborn
  #elif eq.registry.len == 0:
  #  Pending
  else:
    Running

converter toCint(event: epoll_events): uint32 = event.ord.uint32
converter toCint(op: epoll_ctl_op): cint = op.cint

proc eventfd(count: culonglong; flags: cint): Fd
  {.noconv, importc: "eventfd", header: "<sys/eventfd.h>".}

proc epoll_create(flags: cint): Fd
  {.noconv, importc: "epoll_create1", header: "<sys/epoll.h>".}

proc epoll_ctl(epfd: cint; op: cint; fd: cint; event: ptr epoll_event): cint
  {.noconv, importc: "epoll_ctl", header: "<sys/epoll.h>".}

proc epoll_wait(epfd: cint; events: ptr epoll_event;
                maxevents: cint; timeout: cint): cint
  {.noconv, importc: "epoll_wait", header: "<sys/epoll.h>".}

proc newEpollData[T](c: var T; fd: Fd; id: Id): ptr EpollData =
  result = cast[ptr EpollData](alloc sizeof(EpollData)) # XXX: alloca?
  result[] = EpollData(fd: fd, id: id, c: move c)

proc receive(c: Continuation; events: set[Event]): Continuation {.cpsMagic.} =
  echo events
  result = c

proc waitForInterrupt(c: Continuation): Continuation {.cpsMagic.} =
  #var data = newEpollData(id: eq.interruptId, fd: eq.interrupt, c: c)
  #eq.registry.insert(eq.interruptId, data)
  result = nil

proc interruptor() {.cps: Continuation.} =
  var i = 0
  while true:
    inc i
    echo "interrupt " & $i
    waitForInterrupt()

proc register[T](c: var T; fd: Fd; events: set[Event]): Id =
  inc eq.lastId
  result = eq.lastId
  var data = newEpollData(c, fd, result)
  var ev: epoll_event
  # defaults; ERROR and HANGUP are implicit
  ev.events = EPOLLPRI or EPOLLERR or EPOLLHUP
  # event types
  if Read in events:
    ev.events = ev.events or EPOLLIN or EPOLLRDHUP
  if Write in events:
    ev.events = ev.events or EPOLLOUT
  if Level in events:
    raise Defect.newException "not implemented"
  elif Edge in events:
    ev.events = ev.events or EPOLLET
  else:
    raise Defect.newException "specify Edge or Level"
  ev.data = cast[ptr epoll_data_t](data)
  let e = epoll_ctl(eq.interest.cint, EPOLL_CTL_ADD, fd.cint, addr ev)
  doAssert e == 0
  # TODO: store id -> fd ?
  # eq.registry.insert(result, data)

proc init() {.inline.} =
  if eq.state == Newborn:
    eq.interest = epoll_create(O_CLOEXEC)
    eq.interrupt = eventfd(0, O_NONBLOCK or O_CLOEXEC)

    var c = whelp interruptor()
    eq.interruptId = register(c, eq.interrupt, {Read, Edge})
    #assert eq.interruptId in eq.registry

    # registering a fd returns an id to the continuation. when a fd is
    # ready, we use the id to retrieve the continuation. the continuation
    # can also cancel the registration. we must also be able to watch
    # the same fd from multiple continuations, as well as correctly
    # registering and unregistering interest from a given continuation
    # without affecting other continuations. we also need to know exactly
    # which events are associated with which registrations, so that we can
    # correctly unregister interest in an fd.

proc handleError() =
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
    raise Defect.newException "epoll_wait: " & $errno

proc run*(timeout: cint = 1) =
  case eq.state
  of Newborn:
    init()
  of Pending:
    #raise Defect.newException "unlikely"
    discard
  of Running:
    discard
  var event: epoll_event
  let e = epoll_wait(eq.interest.cint, addr event, 1, -1)
  if e == 0:
    echo "timeout or interrupted"
  elif e == -1:
    handleError()
  else:
    let data = cast[ptr EpollData](event.data)
    let id = data.id
    let fd = data.fd
    var c = data.c
    var events: set[Event]
    if 0 != (event.events and EPOLLIN.ord):
      events.incl Read
    if 0 != (event.events and EPOLLOUT.ord):
      events.incl Write
    if 0 != (event.events and EPOLLPRI.ord):
      events.incl Priority
    if 0 != (event.events and EPOLLRDHUP.ord):
      events.incl Hangup
    if 0 != (event.events and EPOLLERR.ord):
      events.incl Error
    if 0 != (event.events and EPOLLHUP.ord):
      events.incl Hangup

proc teardown() =
  case eq.state
  of Newborn:
    discard
  else:
    while EINTR == close eq.interest:
      discard
    #let e = epoll_ctl(eq.interest, EPOLL_CTL_ADD, fd, addr ev)

converter toFd*(s: SocketHandle): Fd = s.Fd
converter toCint*(fd: Fd): cint = fd.cint
converter toCint*(id: Id): cint = id.cint
