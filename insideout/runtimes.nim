import std/atomics
import std/hashes
import std/locks
import std/posix
import std/strutils

import pkg/cps

import insideout/spec as iospec
import insideout/futexes
import insideout/atomic/flags
import insideout/atomic/refs
export refs

import insideout/mailboxes
import insideout/threads
import insideout/eventqueue

export coop

const insideoutAggressiveDealloc {.booldefine.} = false
let insideoutInterruptSignal* = SIGRTMIN
let unmaskedSignals = {SIGINT, SIGTERM, insideoutInterruptSignal}

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

  RuntimeObj = object
    handle: PThread
    parent: PThread
    flags: AtomicFlags32
    signals: Fd
    continuation: Continuation
    error: ref CatchableError

  Runtime* = AtomicRef[RuntimeObj]

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

proc pause*(runtime: Runtime) =
  ## pause a running runtime
  if runtime[].flags.enable Frozen:
    checkWake wakeMask(runtime[].flags, <<Frozen)

proc resume*(runtime: Runtime) =
  ## resume a running runtime
  if runtime[].flags.disable Frozen:
    checkWake wakeMask(runtime[].flags, <<!Frozen)
  interrupt runtime[]

proc waitForFlags(runtime: var RuntimeObj; wants: uint32): bool {.raises: [RuntimeError].} =
  ## wait until the runtime has all of `wants` flags set
  while true:
    var has = get runtime.flags
    result = wants == (has and wants)
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
  result = runtime[].flags.enable Halted
  if result:
    interrupt runtime[]
    checkWake wakeMask(runtime[].flags, <<Halted)

proc join*(runtime: sink Runtime) {.raises: [RuntimeError].} =
  ## block until the runtime has exited
  if not waitForFlags(runtime[], doneFlags):
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
  if runtime[].flags.enable Teardown:
    checkWake wakeMask(runtime[].flags, <<Teardown)
  try:
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
    # don't reset the linked and halted status flags
    let flags = get runtime[].flags
    var also = (flags and <<Linked) or (flags and <<!Linked)
    also = also or (flags and <<Halted) or (flags and <<!Halted)
    put(runtime[].flags, doneFlags or also)
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

proc process(eq: var EventQueue; runtime: var RuntimeObj): cint =
  ## process any events or signals in each iteration of the event loop
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
    CheckState     ## test for cancel, frozen
    RunningPhase   ## running
    FreezePhase    ## entering the frozen state
    FrozenPhase    ## frozen
    HaltPhase      ## exiting before continuation is finished
    ExitPhase      ## exiting

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
      if runtime.continuation.isNil:
        runtime.error = ValueError.newException "nil continuation"
        const bErrorMsg = "nil continuation;"
        nextIf exceptionHandler(runtime.error, bErrorMsg)
      else:
        inc phase
    of RunPhase:
      if runtime.flags.enable Running:
        checkWake wakeMask(runtime.flags, <<Running)
      when insideoutRenameThread:
        nextIf pthread_setname_np(runtime.handle, "io: running")
      else:
        inc phase
    of CheckState:
      pthread_testcancel()
      if flags && <<Frozen:
        phase = FreezePhase
      else:
        inc phase
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
      except CatchableError as e:
        result = exceptionHandler(e, "dispatcher crash;")
        phase = HaltPhase
    of FreezePhase: # we're entering the frozen state
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
            RunPhase
      of ETIMEDOUT:
        runtime.error = RuntimeError.newException "timeout waiting to unfreeze"
        nextIf errno
      else:
        runtime.error = RuntimeError.newException $strerror(errno)
        nextIf errno
    of HaltPhase:
      if runtime.flags.enable Halted:
        checkWake wakeMask(runtime.flags, <<Halted)
      when insideoutRenameThread:
        discard pthread_setname_np(runtime.handle, "io: halted")
      if result == 0:
        result = 1
      inc phase
    of ExitPhase:
      break

proc newSignalHandler*(runtime: Runtime) {.cps: Continuation.} =
  while true:
    coop()
    var info = readSigInfo(runtime[].signals)
    echo getThreadId(), ": ", repr(info)
    case info.ssi_signo.cint
    of SIGQUIT:
      halt runtime
    of SIGCONT:
      resume runtime
    else:
      echo getThreadId(), ": ignore ", info.name
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
    var handler = whelp newSignalHandler(runtime)
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

template spawnCheck(err: cint): untyped =
  let e = err
  if e != 0:
    raise SpawnError.newException: $strerror(e)

proc ignore(sig: cint) {.noconv.} =
  discard

proc setupInterrupts*() =
  ## make sure we can interrupt system calls with some obvious
  ## default signals as well as our custom interruption signal
  for sig in unmaskedSignals.items:
    spawnCheck siginterrupt(sig, 1.cint)
  var sa: Sigaction
  spawnCheck sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  sa.sa_handler = ignore
  spawnCheck sigaction(insideoutInterruptSignal, sa, nil)

proc initSignals(runtime: var RuntimeObj): Sigset =
  let flags = SFD_NONBLOCK or SFD_CLOEXEC
  spawnCheck sigfillset(result)
  for sig in unmaskedSignals.items:
    spawnCheck sigdelset(result, sig)
  once:
    setupInterrupts()

  runtime.signals = signalfd(invalidFd, addr result, flags)
  if invalidFd == runtime.signals:
    raise SpawnError.newException: $strerror(errno)

proc boot(runtime: var RuntimeObj; flags = <<!Linked;
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
    spawnCheck pthread_create(addr runtime.handle, addr attr, thread,
                              cast[pointer](addr runtime))
  except Exception as e:
    raise SpawnError.newException $e.name & ": " & e.msg
  spawnCheck pthread_attr_destroy(addr attr)
  # wait until the thread is done booting
  while get(runtime.flags) && <<Boot:
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
    if flags && <<{Boot, Teardown}:
      raise SpawnError.newException "thread crashed during boot"

proc spawn*(continuation: sink Continuation): Runtime =
  ## run the continuation in another thread
  new result
  result[].continuation = continuation
  boot(result[], flags = <<!Linked)

proc link*(continuation: sink Continuation): Runtime =
  ## run the continuation in another thread;
  ## a failure in the child will propogate to the parent
  new result
  result[].continuation = continuation
  boot(result[], flags = <<Linked)

template spawn*(factory: Callback; mailbox: Mailbox): Runtime =
  spawn factory.call(mailbox)

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
  ## blocks until the continuation is safely ejected.
  if waitForFlags(runtime[], <<!Running):
    result = move runtime[].continuation
  else:
    raise ValueError.newException:
      "runtime must be halted and not running to eject continuation"
