import std/posix
export PThread, PThreadAttr

when (NimMajor, NimMinor) > (1, 6):
  from std/private/threadtypes import pthreadh, SysThread, CpuSet, cpusetZero, cpusetIncl, setAffinity
  export SysThread
elif defined(isNimSkull):
  const
    pthreadh = "#define _GNU_SOURCE\n#include <pthread.h>"
    schedh = "#define _GNU_SOURCE\n#include <sched.h>"
  type CpuSet* {.importc: "cpu_set_t", header: schedh.} = object
    when defined(linux) and defined(amd64):
      abi: array[1024 div (8 * sizeof(culong)), culong]
  proc cpusetZero*(s: var CpuSet)
                  {.importc: "CPU_ZERO", header: schedh.}
  proc cpusetIncl*(cpu: cint; s: var CpuSet)
                  {.importc: "CPU_SET", header: schedh.}
  proc setAffinity*(thread: SysThread; setsize: csize_t; s: var CpuSet)
                   {.importc: "pthread_setaffinity_np", header: pthreadh.}
else:
  #type
  #  PThreadAttr* {.byref, importc: "pthread_attr_t", header: "<sys/types.h>".} = object
  const
    pthreadh* = "#define _GNU_SOURCE\n#include <pthread.h>"
    schedh = "#define _GNU_SOURCE\n#include <sched.h>"

type
  ThreadLike = PThread | SysThread

proc pthread_kill*(thread: ThreadLike; signal: cint)
  {.importc, header: pthreadh.}
proc pthread_join*(thread: ThreadLike; value: ptr pointer): cint
  {.importc, header: pthreadh.}
proc pthread_create*(a1: var ThreadLike, a2: var PThreadAttr,
                     a3: proc (x: pointer): pointer {.noconv.},
                     a4: pointer): cint
  {.importc, header: pthreadh.}
proc pthread_cancel*(thread: ThreadLike): cint
  {.importc, header: pthreadh.}
proc pthread_setcancelstate*(state: cint; oldstate: ptr cint): cint
  {.importc, header: pthreadh.}
proc pthread_setcanceltype*(tipe: cint; oldtipe: ptr cint): cint
  {.importc, header: pthreadh.}
proc pthread_attr_init*(a1: var PThreadAttr): cint
  {.importc, header: pthreadh.}
proc pthread_attr_setstack*(a1: ptr PThreadAttr, a2: pointer, a3: int): cint
  {.importc, header: pthreadh.}
proc pthread_attr_setstacksize*(a1: var PThreadAttr, a2: int): cint
  {.importc, header: pthreadh.}
proc pthread_attr_destroy*(a1: var PThreadAttr): cint
  {.importc, header: pthreadh.}

when defined(macosx):
  proc pthread_setname_np*(name: cstring): cint
    {.importc, header: pthreadh.}

  proc pthread_setname_np*(thread: ThreadLike; name: cstring): cint =
    if pthread_self() == thread:
      result = pthread_setname_np(name)
    else:
      raise Defect.newException:
        "renaming foreign threads is unsupported under osx"
else:
  proc pthread_attr_setsigmask_np*(attr: ptr PThreadAttr, mask: ptr Sigset): cint
    {.importc, header: pthreadh.}
  proc pthread_setname_np*(thread: ThreadLike; name: cstring): cint
    {.importc, header: pthreadh.}
  proc pthread_setname_np*(name: cstring): cint =
    pthread_setname_np(pthread_self(), name)

  # real-time signal range
  let SIGRTMIN* {.importc, header: "<signal.h>".}: cint
  let SIGRTMAX* {.importc, header: "<signal.h>".}: cint

proc pinToCpu*(thread: ThreadLike; cpu: Natural) =
  when not defined(macosx):
    var s {.noinit.}: CpuSet
    cpusetZero(s)
    cpusetIncl(cpu.cint, s)
    setAffinity(SysThread(thread), csize_t(sizeof(s)), s)
