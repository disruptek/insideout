import std/posix
export PThread, PThreadAttr

when (NimMajor, NimMinor) > (1, 6):
  from std/private/threadtypes import pthreadh, SysThread
  export SysThread
else:
  #type
  #  PThreadAttr* {.byref, importc: "pthread_attr_t", header: "<sys/types.h>".} = object
  const
    pthreadh* = "#define _GNU_SOURCE\n#include <pthread.h>"

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
proc pthread_setname_np*(thread: ThreadLike; name: cstring): cint
  {.importc, header: pthreadh.}
