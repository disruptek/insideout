import std/atomics
import std/hashes
import std/locks
import std/posix
import std/strutils

import pkg/cps

import insideout/spec as iospec
import insideout/atomic/flags
import insideout/atomic/refs
export refs

import insideout/eventqueue
import insideout/futexes
import insideout/linked
import insideout/mailboxes
import insideout/threads

export coop

const insideoutAggressiveDealloc {.booldefine.} = false

let insideoutInterruptSignal* = SIGRTMIN
let unmaskedSignals = {insideoutInterruptSignal}

type
  RuntimeError* = object of OSError
  SpawnError* = object of RuntimeError

  RuntimeFlag* {.size: 2.} = enum
    Running    = 0    # 1 / 65536
    Boot       = 1    # 2 / 131072
    Frozen     = 2    # 4 / 262144
    Linked     = 3    # 8 / 524288
    Halted     = 4    # 16 / 1048576
    Teardown   = 5    # 32 / 2097152
    Dead       = 6    # 64 / 4194304

  RuntimeObj {.acyclic.} = object
    handle: PThread
    parent: PThread
    flags: AtomicFlags32
    signals: Fd
    lock: Lock
    continuation: Continuation
    error: ref CatchableError
    linked: LinkedList[AtomicRef[RuntimeObj]]

  Runtime* = AtomicRef[RuntimeObj]

  WaitMode = enum AllFlags, AnyFlags

const deadFlags = <<Dead or <<!{Boot, Teardown, Frozen, Running, Halted, Linked}
const bootFlags = <<Boot or <<!{Dead, Teardown, Frozen, Running, Halted}
const doneFlags = <<Teardown or <<!{Dead, Boot, Frozen, Running}

proc `=copy`*(runtime: var RuntimeObj; other: RuntimeObj) {.error.} =
  ## copies are denied
  discard

proc flags*(runtime: Runtime): uint32 =
  ## return the flags of the runtime
  get runtime[].flags

template withRunning(runtime: Runtime; body: typed): untyped =
  ## execute body if the runtime is running
  if runtime.flags && <<!Teardown:
    body
  else:
    raise ValueError.newException "runtime is not running"

proc hash*(runtime: Runtime): Hash {.deprecated.} =
  ## whatfer inclusion in a table, etc.
  assert not runtime.isNil
  cast[Hash](runtime.address)

proc `$`(thread: PThread or SysThread): string =
  thread.hash.uint32.toHex()

proc `$`(runtime: RuntimeObj): string =
  cast[int](addr runtime).toHex

proc `$`*(runtime: Runtime): string =
  result = "<run:"
  result.add $runtime[]
  result.add ">"

proc `==`*(a, b: Runtime): bool =
  mixin hash
  assert not a.isNil
  assert not b.isNil
  a.address == b.address

proc signal(runtime: var RuntimeObj; sig: int): bool {.used.} =
  ## send a signal to a runtime; true if successful
  0 == pthread_kill(runtime.handle, sig.cint)

proc cancel(runtime: var RuntimeObj): bool {.discardable.} =
  ## cancel a runtime; true if successful
  0 == pthread_cancel(runtime.handle)

proc interrupt(runtime: var RuntimeObj) =
  discard signal(runtime, insideoutInterruptSignal)

proc interrupt*(runtime: Runtime) =
  ## interrupt a running runtime
  interrupt runtime[]

proc freeze*(runtime: Runtime) =
  ## pause a runtime
  while true:
    let flags = get runtime[].flags
    if 0 != (flags and <<!{Teardown, Frozen, Halted}):
      break
    var prior = flags
    let future = (flags xor <<!Frozen) and <<Frozen
    if compareExchange(runtime[].flags, prior, future,
                       order = moSequentiallyConsistent):
      checkWake wakeMask(runtime[].flags, <<Frozen)
      break

proc thaw*(runtime: Runtime) =
  ## resume (unfreeze) a runtime
  if runtime[].flags.disable Frozen:
    checkWake wakeMask(runtime[].flags, <<!Frozen)
  interrupt runtime[]

proc waitForFlags(runtime: var RuntimeObj; mode: WaitMode; wants: uint32): bool {.raises: [RuntimeError].} =
  ## wait until the runtime has all|any of `wants` flags set
  while true:
    var has = get runtime.flags
    result =
      case mode
       of AllFlags: (has and wants) == wants
       of AnyFlags: (has and wants) != 0
    if result:
      break
    let err =
      try:
        checkWait waitMask(runtime.flags, has, wants and not has)
      except FutexError as e:
        raise RuntimeError.newException $e.name & ":" & e.msg
    case err
    of 0, EINTR, EAGAIN:
      discard
    of ETIMEDOUT:
      raise RuntimeError.newException "timeout waiting for thread"
    else:
      raise RuntimeError.newException "unexpected futex error: " & $err

proc halt*(runtime: Runtime): bool {.discardable.} =
  ## ask the runtime to exit; true if the runtime wasn't already halted
  let flags = runtime.flags
  # XXX: raise if the runtime is in a bogus state?
  if flags && <<!Dead:
    result = runtime[].flags.enable Halted
    if result:
      interrupt runtime[]
      checkWake wakeMask(runtime[].flags, <<Halted)

proc join*(runtime: sink Runtime) {.raises: [RuntimeError].} =
  ## block until the runtime has exited
  if not waitForFlags(runtime[], AllFlags, doneFlags):
    raise RuntimeError.newException "runtime failed to exit"

proc cancel*(runtime: Runtime): bool {.discardable.} =
  ## cancel a runtime; true if successful.
  ## always succeeds if the runtime is not running.
  cancel runtime[]

proc `=destroy`(runtime: var RuntimeObj) =
  # reset the flags so that the subsequent wake will
  # not be ignored for any reason
  put(runtime.flags, deadFlags)
  # wake all waiters on the flags in order to free any
  # queued waiters in kernel space
  checkWake wake(runtime.flags)
  reset runtime.linked
  withLock runtime.lock:
    reset runtime.continuation
    reset runtime.error
  deinitLock runtime.lock

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

proc deallocRuntime(runtime: pointer) {.noconv.} =
  ## called by the runtime to deallocate itself from its thread()
  # (we won't get another chance to properly decrement the rc on the runtime)
  block:
    var runtime = cast[Runtime](runtime)
    forget runtime
  when defined(gcOrc):
    {.warning: "insideout does not support orc memory management".}
    GC_runOrc()

template exceptionHandler(e: ref Exception; s: static string): cint =
  ## some exception-handling boilerplate
  {.line: instantiationInfo(fullPaths=true).}:
    when compileOption"stackTrace":
      writeStackTrace()
    stdmsg().writeLine:
      renderError(e, s)
    if errno > 0: errno else: 1

proc teardown(p: pointer) {.noconv.} =
  ## we receive a pointer to a runtime object and we perform any necessary
  ## cleanup; this is run during thread destruction
  mixin dealloc
  var runtime = cast[Runtime](p)
  # make sure we aren't holding the continuation lock
  if runtime[].flags.disable Running:
    release runtime[].lock
    checkWake wakeMask(runtime[].flags, <<!Running)
  try:
    # it seems like the right move is to render the runtime
    # inoperable and let another owner actually dealloc us.
    when insideoutAggressiveDealloc:
      try:
        runtime[].continuation = dealloc(runtime[].continuation, Continuation)
      except CatchableError as e:
        const cErrorMsg = "deallocating continuation;"
        discard e.exceptionHandler cErrorMsg
      try:
        reset runtime[].continuation
      except CatchableError as e:
        const cErrorMsg = "destroying continuation;"
        discard e.exceptionHandler cErrorMsg
  finally:
    # it's time to quiesce the flags, leaving Linked and Halted
    # in place for any post-mortem.  this is where we will halt
    # any linked runtimes.
    let flags = get runtime[].flags
    var also = (flags and <<Linked) or (flags and <<!Linked)
    also = also or (flags and <<Halted) or (flags and <<!Halted)
    put(runtime[].flags, doneFlags or also)
    # wake all waiters on the flags in order to free any queued
    # waiters in kernel space
    checkWake wake(runtime[].flags)
    # perform the halts of any linked peers
    if (also && <<Halted) and (also && <<Linked):
      var peer: Runtime
      while tryPop(runtime[].linked, peer):
        halt peer

template mayCancel(r: typed; body: typed): untyped {.used.} =
  var prior: cint
  r = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE.cint, addr prior)
  try:
    body
  finally:
    r = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior)

const emptyTimeSpec = TimeSpec(tv_sec: 0.Time, tv_nsec: 0.clong)

proc process(eq: var EventQueue; runtime: var RuntimeObj): cint =
  ## process one event or signal in each iteration of the event loop
  var events {.noinit.}: array[1, epoll_event]
  try:
    let ready = eq.wait(events, timeout = addr emptyTimeSpec, nil)
    if ready == -1:
      result = errno
    elif ready > 0:
      eq.run(events, ready)
      eq.pruneOneShots(events, ready)
  except CatchableError as e:
    const pErrorMsg = "event handler crash;"
    result = e.exceptionHandler pErrorMsg

type
  Phase = enum
    BootPhase      ## instantiate continuation
    RunPhase       ## entering the running state
    RunningPhase   ## running
    FreezePhase    ## entering the frozen state
    FrozenPhase    ## frozen
    HaltPhase      ## exiting before continuation is finished
    ExitPhase      ## exiting

const CheckState = RunPhase

proc inc(p: var Phase) =
  p = Phase: p.ord + 1

proc loop(eq: var EventQueue; runtime: var RuntimeObj): cint =
  ## the main event loop which operates the runtime
  var phase: Phase

  template nextIf(err: untyped): untyped {.dirty.} =
    result = err
    if result == 0:
      inc phase
    else:
      phase = HaltPhase

  var flags: uint32
  while phase != ExitPhase:
    # process any events or signals
    if not eq.isNil:
      result = eq.process(runtime)

    # read the flags at each iteration
    flags = get runtime.flags

    # see if we need to shutdown the loop...
    if result != 0 or flags && <<Halted:
      phase = HaltPhase

    case phase
    of BootPhase:
      # check for a bogus/missing factory composition
      withLock runtime.lock:
        if runtime.continuation.isNil:
          runtime.error = ValueError.newException "nil continuation"
          const bErrorMsg = "nil continuation;"
          nextIf exceptionHandler(runtime.error, bErrorMsg)
        else:
          inc phase
    of RunPhase:
      if flags && <<Frozen:
        phase = FreezePhase
      else:
        if runtime.flags.enable Running:
          acquire runtime.lock
          checkWake wakeMask(runtime.flags, <<Running)
          when insideoutRenameThread:
            nextIf pthread_setname_np(runtime.handle, "io: running")
          else:
            inc phase
        else:
          inc phase
      pthread_testcancel()
    of RunningPhase:
      try:
        var fn: ContinuationFn = runtime.continuation.fn

        # NOTE: if the thread is cancelled or the continuation
        # crashes here, we need to be able to free its environment
        # from within teardown()

        {.push objChecks: off.}
        var temporary: Continuation = fn(runtime.continuation)
        runtime.continuation = temporary
        {.pop.}

        phase =
          if runtime.continuation.isNil:
            ExitPhase
          elif runtime.continuation.fn.isNil:
            ExitPhase
          else:
            CheckState
        when defined(isNimSkull):
          echo "nimskull bug #", 0.toHex
      except CatchableError as e:
        result = exceptionHandler(e, "dispatcher crash;")
        phase = HaltPhase
    of FreezePhase: # we're entering the frozen state
      if runtime.flags.disable Running:
        release runtime.lock
        checkWake wakeMask(runtime.flags, <<!Running)
      when insideoutRenameThread:
        nextIf pthread_setname_np(runtime.handle, "io: frozen")
      else:
        inc phase
    of FrozenPhase:
      case checkWait waitMask(runtime.flags, flags, <<Halted + <<!Frozen)
      of EINTR:
        discard
      of 0, EAGAIN:
        let flags = get runtime.flags
        phase =
          if flags && <<Halted:      # halted while frozen
            HaltPhase
          elif flags && <<Frozen:    # spurious wakeup
            FrozenPhase              # loop and don't rename thread
          else:                      # unfrozen
            CheckState
      of ETIMEDOUT:
        runtime.error = RuntimeError.newException "timeout waiting to unfreeze"
        nextIf errno
      else:
        runtime.error = RuntimeError.newException $strerror(errno)
        nextIf errno
    of HaltPhase:
      if result == 0:
        result = 1
      if runtime.flags.enable Halted:
        checkWake wakeMask(runtime.flags, <<Halted)
      when insideoutRenameThread:
        discard pthread_setname_np(runtime.handle, "io: halted")
      inc phase
    of ExitPhase:
      break

template spawnCheck(err: cint): untyped =
  {.line: instantiationInfo(fullPaths=true).}:
    let e = err
    if e != 0:
      raise SpawnError.newException: $strerror(e)

template checkSig(err: cint): untyped =
  {.line: instantiationInfo(fullPaths=true).}:
    if err.cint == -1:
      raise RuntimeError.newException $strerror(errno)

proc ignore(sig: cint) {.noconv.} =
  discard

proc setupInterrupts*() {.raises: [RuntimeError].} =
  ## make sure we can interrupt system calls with some obvious
  ## default signals as well as our custom interruption signal
  for sig in unmaskedSignals.items:
    checkSig siginterrupt(sig, 1.cint)
  var sa: Sigaction
  checkSig sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  sa.sa_handler = ignore
  checkSig sigaction(insideoutInterruptSignal, sa, nil)

proc initSignalFd*(mask: Sigset): Fd {.raises: [RuntimeError].} =
  ## create a new signal file descriptor
  result = signalfd(invalidFd, addr mask, SFD_NONBLOCK or SFD_CLOEXEC)
  if invalidFd == result:
    raise RuntimeError.newException: $strerror(errno)

proc signalMask*(): Sigset {.raises: [RuntimeError].} =
  let flags = SFD_NONBLOCK or SFD_CLOEXEC
  if 0 != sigfillset(result):
    raise RuntimeError.newException "unable to compose signal mask"
  for sig in unmaskedSignals.items:
    if 0 != sigdelset(result, sig):
      raise RuntimeError.newException "unable to compose signal mask"
  once:
    setupInterrupts()

proc signalMask(runtime: var RuntimeObj): Sigset {.raises: [RuntimeError].} =
  signalMask()

proc newSignalHandler*(runtime: Runtime; fd: Fd) {.cps: Continuation.} =
  while true:
    coop()
    var info = fd.readSigInfo()
    case info.ssi_signo.cint
    of SIGINT:
      # if we're here, well, mission accomplished
      discard
    of SIGTERM, SIGQUIT:
      halt runtime
    of SIGCONT:
      thaw runtime
    else:
      echo getThreadId(), ": ignore ", repr(info)
      discard
    dismiss()

proc dispatcher(runtime: sink Runtime): cint =
  ## blocking dispatcher for a runtime
  pthread_cleanup_push(teardown, runtime.address)

  # enable cancellation or die trying
  result = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE.cint, nil)
  if result != 0:
    stdmsg().writeLine:
      renderError(RuntimeError.newException "unable to enable cancellation")
  else:
    var mask = signalMask(runtime[])
    runtime[].signals = initSignalFd(mask)
    var handler = whelp newSignalHandler(runtime, runtime[].signals)
    withNewEventQueue eq:
      if runtime[].signals != invalidFd:
        discard eq.register(handler, runtime[].signals, {Edge, Read})

      # release the thread creator; this thread is done booting
      if runtime[].flags.disable Boot:
        checkWake wakeMask(runtime[].flags, <<!Boot)

      if result == 0:
        result = loop(eq, runtime[])

  pthread_exit(addr result)
  pthread_cleanup_pop(0)

proc thread(p: pointer): pointer {.noconv.} =
  ## our entrance into the new thread; we receive a RuntimeObj
  var prior: cint
  if 0 != pthread_setcancelstate(PTHREAD_CANCEL_DISABLE.cint, addr prior):
    raise RuntimeError.newException "unable to set cancel state on a new thread"
  # NOTE: deferred probably won't make sense until we're on eventfd
  #elif 0 != pthread_setcanceltype(PTHREAD_CANCEL_DEFERRED.cint, addr prior):
  elif 0 != pthread_setcanceltype(PTHREAD_CANCEL_ASYNCHRONOUS.cint, addr prior):
    raise RuntimeError.newException "unable to set cancel type on a new thread"
  else:
    var runtime = cast[Runtime](p)
    # push the dealloc here because it's more correct
    pthread_cleanup_push(deallocRuntime, runtime.address)
    # drop into the dispatcher (and never come back)
    discard dispatcher(move runtime)
    pthread_cleanup_pop(0)

proc boot(runtime: var RuntimeObj; size = insideoutStackSize)
  {.raises: [SpawnError, RuntimeError].} =
  ## perform remaining setup of the runtime and boot the thread
  let mask = signalMask runtime
  var attr {.noinit.}: PThreadAttr
  spawnCheck pthread_attr_init(addr attr)
  spawnCheck pthread_attr_setsigmask_np(addr attr, addr mask)
  spawnCheck pthread_attr_setdetachstate(addr attr, PTHREAD_CREATE_DETACHED)
  spawnCheck pthread_attr_setstacksize(addr attr, size.cint)
  runtime.parent = pthread_self()
  try:
    spawnCheck pthread_create(addr runtime.handle, addr attr, thread,
                              cast[pointer](addr runtime))
  except Exception as e:
    raise SpawnError.newException $e.name & ": " & e.msg
  spawnCheck pthread_attr_destroy(addr attr)
  # wait until the thread is done booting
  var flags = get runtime.flags
  while flags && <<Boot:
    var err =
      try:
        checkWait waitMask(runtime.flags, flags, <<!Boot or <<Teardown)
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
    flags = get runtime.flags
    if flags && <<{Boot, Teardown}:
      raise SpawnError.newException "thread crashed during boot"

proc pinToCpu*(runtime: Runtime; cpu: Natural) =
  ## assign a runtime to a specific cpu index
  withRunning runtime:
    pinToCpu(runtime[].handle, cpu)

proc handle*(runtime: Runtime): PThread =
  withRunning runtime:
    runtime[].handle

proc signal*(runtime: Runtime; sig: int): bool {.discardable.} =
  ## send a signal to a runtime; true if successful
  signal(runtime[], sig)

proc eject*(runtime: Runtime): Continuation {.discardable.} =
  ## remove the continuation from a runtime;
  ## blocks until the continuation is safely ejected
  ## and leaves the runtime in a Frozen state.
  freeze runtime
  if waitForFlags(runtime[], AllFlags, <<!Running):
    withLock runtime[].lock:
      result = move runtime[].continuation
  else:
    raise ValueError.newException:
      "cannot eject continuation from running runtime"

proc init(runtime: var RuntimeObj; continuation: sink Continuation) =
  init runtime.linked
  initLock runtime.lock
  runtime.continuation = move continuation
  runtime.signals = invalidFd
  put(runtime.flags, bootFlags)

proc link1(parent, child: AtomicRef[RuntimeObj]) =
  ## link two runtimes; a failure of
  ## the parent will halt the child
  if parent.flags && <<!Teardown:  # XXX: allow in Teardown?
    link1(parent[].linked, child):
      if parent[].flags.enable Linked:
        checkWake wakeMask(parent[].flags, <<Linked)

proc unlink1(parent, child: AtomicRef[RuntimeObj]) =
  ## unlink a child from the parent; a failure of
  ## the child will have no effect on the parent
  if parent.flags && <<!Teardown:  # XXX: allow in Teardown?
    unlink1(parent[].linked, child):
      discard
  # XXX: keep the lock?
  ifEmpty parent[].linked:
    if parent[].flags.disable Linked:
      checkWake wakeMask(parent[].flags, <<!Linked)

proc link*(a, b: Runtime) =
  ## link two runtimes; a failure of either will halt the other
  if a == b: raise ValueError.newException "cannot link a runtime to itself"
  link1(a, b)
  link1(b, a)

proc unlink*(a, b: Runtime) =
  ## unlink two linked runtimes; each may fail independently
  if a == b: return
  unlink1(a, b)
  unlink1(b, a)

proc spawn*(continuation: sink Continuation): Runtime =
  ## run the continuation in another thread
  new result
  result[].init(continuation)
  boot result[]

proc spawnLink*(runtime: Runtime; continuation: sink Continuation): Runtime =
  ## run the continuation in another thread; link it to `runtime`
  new result
  result[].init(continuation)
  link(runtime, result)
  boot result[]

template spawn*(factory: Callback; mailbox: Mailbox): Runtime =
  spawn factory.call(mailbox)
