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

const
  insideoutStackSize* {.intdefine.} = 16_384
  insideoutRenameThread* {.booldefine.} = defined(linux)

type
  RuntimeError* = object of OSError
  SpawnError* = object of RuntimeError
  Dispatcher* = proc(p: pointer): pointer {.noconv.}
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
  #if runtime.owners > 1:
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
    when key == "flags":
      discard
    elif key == "signals":
      if value != invalidFd:
        while EINTR == close value:
          discard
        value = invalidFd
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

proc bounce*[T: Continuation](c: sink T): T =
  var c: Continuation = move c
  var fn = c.fn
  result = T fn(move c)

type
  ContinuationFn = proc (c: sink Continuation): Continuation {.nimcall.}

proc deallocRuntime[A, B](runtime: pointer) {.noconv.} =
  ## called by the runtime to deallocate itself from its thread()
  # (we won't get another chance to properly decrement the rc on the runtime)
  block:
    var runtime = cast[Runtime[A, B]](runtime)
    forget runtime
  when defined(gcOrc):
    {.warning: "insideout does not support orc memory management".}
    GC_runOrc()

proc teardown[A, B](p: pointer) {.noconv.} =
  ## we receive a pointer to a runtime object and we perform any necessary
  ## cleanup; this is run during thread destruction
  var runtime = cast[Runtime[A, B]](p)
  if runtime[].flags.enable Halted:
    checkWake wakeMask(runtime[].flags, <<Halted)
  try:
    try:
      reset runtime[].continuation
    except CatchableError as e:
      const cErrorMsg = "destroying " & $A & " continuation;"
      stdmsg().writeLine:
        renderError(e, cErrorMsg)
    try:
      reset runtime[].mailbox
    except CatchableError as e:
      const mErrorMsg = "discarding " & $B & " mailbox;"
      stdmsg().writeLine:
        renderError(e, mErrorMsg)
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

proc dispatcher[A, B](runtime: sink Runtime[A, B]): cint =
  ## blocking dispatcher for a runtime
  pthread_cleanup_push(teardown[A, B], runtime.address)
  var prior: cint

  # now that we can safely handle a cancellation, release the thread creator
  if runtime[].flags.enable Running:
    checkWake wakeMask(runtime[].flags, <<Running)

  # enable cancellation or die trying
  result = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE.cint, addr prior)
  if result != 0:
    stdmsg().writeLine:
      renderError(Defect.newException "unable to enable cancellation")
    pthread_exit(addr result)

  var phase = 0
  template nextIf(err: untyped): untyped {.dirty.} =
    result = err
    if result == 0:
      inc phase
  var flags: uint32
  while true:
    if result == 0:
      flags = get runtime[].flags
      if flags && <<Halted:
        phase = high int
        result = 1
    else:
      if runtime[].flags.enable Halted:
        checkWake wakeMask(runtime[].flags, <<Halted)
      phase = high int
    case phase
    of 0:
      # boot the continuation if we haven't already done so
      if runtime[].continuation.isNil:
        runtime[].continuation = runtime[].factory.call(runtime[].mailbox)
      # check for a bogus/missing factory composition
      if runtime[].continuation.isNil:
        runtime[].error = ValueError.newException "nil continuation"
        nextIf 1
      else:
        inc phase
    of 1:
      when insideoutRenameThread:
        nextIf pthread_setname_np(runtime[].handle, "io: running")
      else:
        inc phase
    of 2:
      # if the runtime is frozen, we need to wait for it to thaw
      if flags && <<Frozen:
        phase = 4
      else:
        inc phase
    of 3:
      try:
        var fn: ContinuationFn = runtime[].continuation.fn

        # NOTE: if the thread is cancelled or the continuation
        # crashes here, we need to be able to free its environment
        # from within teardown()

        var temporary: Continuation = fn(runtime[].continuation)
        runtime[].continuation = A temporary

        if not runtime[].continuation.isNil and not runtime[].continuation.fn.isNil:
          dec phase  # check to see if we've been frozen
        else:
          break      # normal termination
      except CatchableError as e:
        when compileOption"stackTrace":
          writeStackTrace()
        const cErrorMsg = $A & " dispatcher crash;"
        stdmsg().writeLine:
          renderError(e, cErrorMsg)
        nextIf errno  # either way, we're done
    of 4:
      when insideoutRenameThread:
        nextIf pthread_setname_np(runtime[].handle, "io: frozen")
      else:
        inc phase
    of 5:
      case checkWait waitMask(runtime[].flags, flags, <<Halted + <<!Frozen)
      of EINTR:
        discard
      of 0, EAGAIN:
        let flags = get runtime[].flags
        if flags && <<Halted:      # halted while frozen
          phase = high int
        elif flags && <<Frozen:    # spurious wakeup
          phase = 5                # loop and don't rename thread
        else:                      # unfrozen
          phase = 0
      of ETIMEDOUT:
        runtime[].error = RuntimeError.newException "timeout waiting to unfreeze"
        nextIf 1
      else:
        runtime[].error = RuntimeError.newException $strerror(errno)
        nextIf errno
    else:
      when insideoutRenameThread:
        discard pthread_setname_np(runtime[].handle, "io: halted")
      result = 1
      break

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
  runtime.signals = Fd signalfd(-1.cint, addr result, flags)
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

proc spawn[A, void](runtime: var RuntimeObj[A, void]; continuation: sink A) =
  ## run the continuation in another thread
  runtime.continuation = continuation
  boot runtime

proc link[A, void](runtime: var RuntimeObj[A, void]; continuation: sink A) =
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

proc spawn*[A](continuation: sink A): Runtime[A, Mailbox[void]] =
  new result
  spawn[A, Mailbox[void]](result[], continuation)

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
