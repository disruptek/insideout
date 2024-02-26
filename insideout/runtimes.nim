import std/atomics
import std/hashes
import std/locks
import std/posix
import std/strutils

import pkg/cps

import insideout/spec
import insideout/futexes
import insideout/atomic/flags
import insideout/atomic/refs
export refs

import insideout/mailboxes
import insideout/threads
import insideout/eventqueue

export coop

type
  RuntimeError* = object of OSError
  SpawnError* = object of RuntimeError
  Factory*[A, B] = proc(mailbox: Mailbox[B]) {.cps: A.}

  RuntimeFlag* {.size: 2.} = enum
    Halted     = 0    # 1 / 65536
    Frozen     = 1    # 2 / 131072
    Running    = 2    # 4 / 262144
    Linked     = 3    # 8 / 524288

  RuntimeObj[A, B] = object
    handle: PThread
    parent: PThread
    flags: AtomicFlags32
    eq: EventQueue
    signals: Fd
    factory: Factory[A, B]
    mailbox: Mailbox[B]
    continuation: A
    error: ref CatchableError

  Runtime*[A, B] = AtomicRef[RuntimeObj[A, B]]

const deadFlags = <<Halted or <<!{Frozen, Running, Linked}
const bootFlags = <<!{Halted, Frozen, Running}

proc `=copy`*[A, B](runtime: var RuntimeObj[A, B]; other: RuntimeObj[A, B]) {.error.} =
  ## copies are denied
  discard

proc state*[A, B](runtime: Runtime[A, B]): RuntimeFlag =
  ## return the state of the runtime
  assert not runtime.isNil
  let flags = get runtime[].flags
  if flags && <<Halted:
    Halted
  elif flags && <<Frozen:
    Frozen
  elif flags && <<Running:
    Running
  else:
    raise Defect.newException "unexpected runtime flags: " & $flags
    Halted

template withRunning[A, B](runtime: Runtime[A, B]; body: typed): untyped =
  ## execute body if the runtime is running
  assert not runtime.isNil
  let state = runtime.state
  if state == Running:
    body
  else:
    raise ValueError.newException "runtime is " & $state

proc hash*(runtime: Runtime): Hash {.deprecated.} =
  ## whatfer inclusion in a table, etc.
  assert not runtime.isNil
  cast[Hash](runtime.address)

proc `$`(thread: PThread or SysThread): string =
  thread.hash.uint32.toHex()

proc `$`(runtime: RuntimeObj): string =
  cast[int](addr runtime).toHex

proc `$`*[A, B](runtime: Runtime[A, B]): string =
  assert not runtime.isNil
  result = "<run:"
  result.add $runtime[]
  result.add "-"
  result.add $runtime.state
  result.add ">"

proc `==`*(a, b: Runtime): bool =
  mixin hash
  assert not a.isNil
  assert not b.isNil
  a.address == b.address

proc cancel[A, B](runtime: var RuntimeObj[A, B]): bool {.discardable.} =
  ## cancel a runtime; true if successful
  result = 0 == pthread_cancel(runtime.handle)

proc signal[A, B](runtime: var RuntimeObj[A, B]; sig: int): bool {.used.} =
  ## send a signal to a runtime; true if successful
  let flags = get runtime.flags
  if flags && (<<!Halted + <<Running):  # FIXME: allow signals in teardown?
    result = 0 == pthread_kill(runtime.handle, sig.cint)

proc kill[A, B](runtime: var RuntimeObj[A, B]): bool {.used.} =
  ## kill a runtime; false if the runtime is not running
  signal(runtime, 9)

proc waitForFlags[A, B](runtime: var RuntimeObj[A, B]; wants: uint32): bool {.raises: [RuntimeError].} =
  while true:
    var has = get runtime.flags
    result = 0 != (has and wants)
    if result:
      break
    let err =
      try:
        checkWait waitMask(runtime.flags, has, wants)
      except FutexError as e:
        raise RuntimeError.newException $e.name & ":" & e.msg
    case err
    of 0, EINTR, EAGAIN:
      discard
    of ETIMEDOUT:
      raise RuntimeError.newException "timeout waiting for thread"
    else:
      raise RuntimeError.newException "unexpected futex error: " & $err

proc halt*[A, B](runtime: Runtime[A, B]): bool {.discardable.} =
  ## ask the runtime to exit; true if the runtime wasn't already halted
  assert not runtime.isNil
  result = runtime[].flags.enable Halted
  if result:
    checkWake wakeMask(runtime[].flags, <<Halted)

proc join*[A, B](runtime: sink Runtime[A, B]) {.raises: [RuntimeError].} =
  ## block until the runtime has exited
  assert not runtime.isNil
  if not waitForFlags(runtime[], <<!Running):
    raise RuntimeError.newException "runtime failed to exit"

proc cancel*[A, B](runtime: Runtime[A, B]): bool {.discardable.} =
  ## cancel a runtime; true if successful.
  ## always succeeds if the runtime is not running.
  assert not runtime.isNil
  cancel runtime[]

proc `=destroy`[A, B](runtime: var RuntimeObj[A, B]) =
  # reset the flags so that the subsequent wake will
  # not be ignored for any reason
  put(runtime.flags, deadFlags)
  # wake all waiters on the flags in order to free any
  # queued waiters in kernel space
  checkWake wake(runtime.flags)
  for key, value in runtime.fieldPairs:
    when value is Fd:
      close value
    elif value is AtomicFlags32:
      discard
    else:
      reset value

proc renderError(e: ref Exception; s = "crash;"): string =
  result = newStringOfCap(16 + s.len + e.name.len + e.msg.len)
  result.add "#"
  result.add $getThreadId()
  result.add " "
  result.add s
  result.add " "
  result.add e.name
  result.add ": "
  result.add e.msg

type
  ContinuationFn = proc (c: sink Continuation): Continuation {.nimcall.}

proc bounce*[T: Continuation](c: sink T): T =
  var c: Continuation = move c
  var fn: ContinuationFn = c.fn
  result = T fn(move c)

proc deallocRuntime[A, B](runtime: pointer) {.noconv.} =
  ## called by the runtime to deallocate itself from its thread()
  # (we won't get another chance to properly decrement the rc on the runtime)
  block:
    var runtime = cast[Runtime[A, B]](runtime)
    forget runtime
  when defined(gcOrc):
    {.warning: "insideout does not support orc memory management".}
    GC_runOrc()

template exceptionHandler(e: ref Exception; s: static string): cint =
  ## some exception-handling boilerplate
  when compileOption"stackTrace":
    writeStackTrace()
  stdmsg().writeLine:
    renderError(e, s)
  if errno > 0: errno else: 1

proc teardown[A, B](p: pointer) {.noconv.} =
  ## we receive a pointer to a runtime object and we perform any necessary
  ## cleanup; this is run during thread destruction
  mixin dealloc
  var runtime = cast[Runtime[A, B]](p)
  if runtime[].flags.enable Halted:
    checkWake wakeMask(runtime[].flags, <<Halted)
  try:
    try:
      runtime[].continuation = dealloc(runtime[].continuation, A)
    except CatchableError as e:
      const cErrorMsg = "deallocating " & $A & " continuation;"
      discard e.exceptionHandler cErrorMsg
    try:
      reset runtime[].continuation
    except CatchableError as e:
      const cErrorMsg = "destroying " & $A & " continuation;"
      discard e.exceptionHandler cErrorMsg
    try:
      reset runtime[].mailbox
    except CatchableError as e:
      const mErrorMsg = "discarding " & $B & " mailbox;"
      discard e.exceptionHandler mErrorMsg
  finally:
    put(runtime[].flags, <<!{Running, Frozen} or <<Halted)
    # wake all waiters on the flags in order to free any queued
    # waiters in kernel space
    checkWake wake(runtime[].flags)

template mayCancel(r: typed; body: typed): untyped {.used.} =
  var prior: cint
  r = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE.cint, addr prior)
  try:
    body
  finally:
    r = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)

const emptyTimeSpec = TimeSpec(tv_sec: 0.Time, tv_nsec: 0.clong)

proc process[A, B](eq: var EventQueue; runtime: var RuntimeObj[A, B]): cint =
  ## process any events or signals in each iteration of the event loop
  var events {.noinit.}: array[1, epoll_event]
  try:
    let ready = eq.wait(events, timeout = addr emptyTimeSpec, nil)
    if ready == -1:
      result = errno
    else:
      eq.run(events, ready)
      eq.pruneOneShots(events, ready)
  except CatchableError as e:
    const pErrorMsg = $A & " event handler crash;"
    result = e.exceptionHandler pErrorMsg

proc loop[A, B](eq: var EventQueue; runtime: var RuntimeObj[A, B]): cint =
  ## the main event loop which operates the runtime
  const pleaseHalt = high int
  var phase: int

  template nextIf(err: untyped): untyped {.dirty.} =
    result = err
    if result == 0:
      inc phase
    else:
      phase = pleaseHalt

  var flags: uint32
  while true:
    # process any events or signals
    result = eq.process(runtime)

    # check the state every iteration
    flags = get runtime.flags

    # see if we need to shutdown the loop...
    if result != 0 or flags && <<Halted:
      phase = pleaseHalt

    case phase
    of 0: # boot the continuation if we haven't already done so
      if runtime.continuation.isNil:
        runtime.continuation = runtime.factory.call(runtime.mailbox)
      # check for a bogus/missing factory composition
      if runtime.continuation.isNil:
        runtime.error = ValueError.newException "nil continuation"
        nextIf 1
      else:
        inc phase
    of 1: # rename the thread to indicate that we're running
      when insideoutRenameThread:
        nextIf pthread_setname_np(runtime.handle, "io: running")
      else:
        inc phase
    of 2: # if the runtime is frozen, we need to wait for it to thaw
      if flags && <<Frozen:
        phase = 4
      else:
        inc phase
    of 3: # we're running a continuation normally
      try:
        var fn: ContinuationFn = runtime.continuation.fn

        # NOTE: if the thread is cancelled or the continuation
        # crashes here, we need to be able to free its environment
        # from within teardown()

        {.push objChecks: off.}                    # old nim
        var temporary: Continuation = fn(runtime.continuation)
        runtime.continuation = cast[A](temporary)  # nimskull
        {.pop.}

        # verbosity due to sanitizers
        if not runtime.continuation.isNil and not runtime.continuation.fn.isNil:
          dec phase  # check to see if we've been frozen
        else:
          break      # normal termination of the event loop
      except CatchableError as e:
        result = exceptionHandler(e, $A & " dispatcher crash;")
        phase = pleaseHalt
    of 4: # we're entering the frozen state
      when insideoutRenameThread:
        nextIf pthread_setname_np(runtime.handle, "io: frozen")
      else:
        inc phase
    of 5: # the frozen state, where we wait for the runtime to thaw
      case checkWait waitMask(runtime.flags, flags, <<Halted + <<!Frozen)
      of EINTR:
        discard
      of 0, EAGAIN:
        let flags = get runtime.flags
        if flags && <<Halted:      # halted while frozen
          phase = high int
        elif flags && <<Frozen:    # spurious wakeup
          phase = 5                # loop and don't rename thread
        else:                      # unfrozen
          phase = 0
      of ETIMEDOUT:
        runtime.error = RuntimeError.newException "timeout waiting to unfreeze"
        nextIf errno
      else:
        runtime.error = RuntimeError.newException $strerror(errno)
        nextIf errno
    else: # we're crashing out of the loop
      when insideoutRenameThread:
        discard pthread_setname_np(runtime.handle, "io: halted")
      if result == 0:
        result = 1
      break

proc dispatcher[A, B](runtime: sink Runtime[A, B]): cint =
  ## blocking dispatcher for a runtime
  pthread_cleanup_push(teardown[A, B], runtime.address)

  # now that we can safely handle a cancellation, release the thread creator
  if runtime[].flags.enable Running:
    checkWake wakeMask(runtime[].flags, <<Running)

  # enable cancellation or die trying
  result = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE.cint, nil)
  if result != 0:
    stdmsg().writeLine:
      renderError(Defect.newException "unable to enable cancellation")
  else:
    withNewEventQueue eq:
      # this right here, is where the rubber meets the road
      when false:
        if runtime[].signals != invalidFd:
          eq.register(runtime[].signals, {Read})
      result = loop(eq, runtime[])

  pthread_exit(addr result)
  pthread_cleanup_pop(0)

proc thread[A, B](p: pointer): pointer {.noconv.} =
  ## our entrance into the new thread; we receive a RuntimeObj
  var prior: cint
  if 0 != pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior):
    raise Defect.newException "unable to set cancel state on a new thread"
  # NOTE: deferred probably won't make sense until we're on eventfd
  #elif 0 != pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED.cint, addr prior):
  elif 0 != pthread_setcanceltype(PTHREAD_CANCEL_ASYNCHRONOUS.cint, addr prior):
    raise Defect.newException "unable to set cancel type on a new thread"
  else:
    var runtime = cast[Runtime[A, B]](p)
    # push the dealloc here because it's more correct
    pthread_cleanup_push(deallocRuntime[A, B], runtime.address)
    # drop into the dispatcher (and never come back)
    discard dispatcher(move runtime)
    pthread_cleanup_pop(0)

template spawnCheck(err: cint): untyped =
  let e = err
  if e != 0:
    raise SpawnError.newException: $strerror(e)

proc initSignals[A, B](runtime: var RuntimeObj[A, B]): Sigset =
  let flags = SFD_NONBLOCK or SFD_CLOEXEC
  spawnCheck sigfillset(result)
  runtime.signals = signalfd(invalidFd, addr result, flags)
  if invalidFd == runtime.signals:
    raise SpawnError.newException: $strerror(errno)

proc boot[A, B](runtime: var RuntimeObj[A, B]; flags = <<!Linked;
                size = insideoutStackSize) {.raises: [SpawnError].} =
  ## perform remaining setup of the runtime and boot the thread
  let mask = initSignals runtime
  let flags = flags or bootFlags
  var attr {.noinit.}: PThreadAttr
  spawnCheck pthread_attr_init(addr attr)
  spawnCheck pthread_attr_setsigmask_np(addr attr, addr mask)
  spawnCheck pthread_attr_setdetachstate(addr attr, PTHREAD_CREATE_DETACHED)
  spawnCheck pthread_attr_setstacksize(addr attr, size.cint)
  put(runtime.flags, flags)
  runtime.parent = pthread_self()
  try:
    spawnCheck pthread_create(addr runtime.handle, addr attr, thread[A, B],
                              cast[pointer](addr runtime))
  except Exception as e:
    raise SpawnError.newException $e.name & ": " & e.msg
  spawnCheck pthread_attr_destroy(addr attr)
  while get(runtime.flags) == flags:
    # if the flags changed at all, the thread launch is successful
    var err =
      try:
        checkWait wait(runtime.flags, flags)
      except FutexError as e:
        raise SpawnError.newException e.msg
        errno
    case err
    of 0, EINTR, EAGAIN:
      discard
    of ETIMEDOUT:
      raise SpawnError.newException "timeout waiting for thread to boot"
    else:
      raise SpawnError.newException "unexpected futex errno: " & $err

proc spawn[A](runtime: var RuntimeObj[A, void]; continuation: sink A) =
  ## run the continuation in another thread
  runtime.continuation = continuation
  boot(runtime, flags = <<!Linked)

proc link[A](runtime: var RuntimeObj[A, void]; continuation: sink A) =
  ## run the continuation in another thread; a failure in the child will
  ## propogate to the parent
  runtime.continuation = continuation
  boot(runtime, flags = <<Linked)

proc spawn[A, B](runtime: var RuntimeObj[A, B]; factory: Factory[A, B]; mailbox: Mailbox[B]) =
  ## add compute to mailbox
  runtime.factory = factory
  runtime.mailbox = mailbox
  when not defined(danger):  # if this isn't dangerous, i don't know what is
    if runtime.mailbox.isNil:
      raise ValueError.newException "nil mailbox"
    elif runtime.factory.fn.isNil:
      raise ValueError.newException "nil factory function"
  boot runtime

proc spawn*[A, B](factory: Factory[A, B]; mailbox: Mailbox[B]): Runtime[A, B] =
  ## create compute from a factory and mailbox
  new result
  spawn(result[], factory, mailbox)

proc spawn*[A](continuation: sink A): Runtime[A, void] =
  new result
  spawn(result[], continuation)

proc factory*[A, B](runtime: Runtime[A, B]): Factory[A, B] {.deprecated.} =
  ## recover the factory from the runtime
  assert not runtime.isNil
  runtime[].factory

proc mailbox*[A, B](runtime: Runtime[A, B]): Mailbox[B] {.deprecated.} =
  ## recover the mailbox from the runtime
  assert not runtime.isNil
  runtime[].mailbox

proc pinToCpu*[A, B](runtime: Runtime[A, B]; cpu: Natural) =
  ## assign a runtime to a specific cpu index
  withRunning runtime:
    pinToCpu(runtime[].handle, cpu)

proc handle*[A, B](runtime: Runtime[A, B]): PThread =
  withRunning runtime:
    runtime[].handle

proc pause*[A, B](runtime: Runtime[A, B]) =
  ## pause a running runtime
  if runtime[].flags.enable Frozen:
    checkWake wakeMask(runtime[].flags, <<Frozen)

proc resume*[A, B](runtime: Runtime[A, B]) =
  ## resume a running runtime
  if runtime[].flags.disable Frozen:
    checkWake wakeMask(runtime[].flags, <<!Frozen)

template stop*[A, B](runtime: Runtime[A, B]) {.deprecated.} = halt runtime
