from std/private/threadtypes import pthreadh, SysThread, PthreadAttr

proc pthread_kill*(thread: SysThread; signal: cint)
  {.importc, header: pthreadh.}
proc pthread_join*(thread: SysThread; value: ptr pointer): cint
  {.importc, header: pthreadh.}
proc pthread_create*(a1: var SysThread, a2: var Pthread_attr,
                     a3: proc (x: pointer): pointer {.noconv.},
                     a4: pointer): cint
  {.importc, header: pthreadh.}
proc pthread_cancel*(thread: SysThread): cint
  {.importc, header: pthreadh.}
proc pthread_attr_init*(a1: var Pthread_attr): cint
  {.importc, header: pthreadh.}
proc pthread_attr_setstack*(a1: ptr Pthread_attr, a2: pointer, a3: int): cint
  {.importc, header: pthreadh.}
proc pthread_attr_setstacksize*(a1: var Pthread_attr, a2: int): cint
  {.importc, header: pthreadh.}
proc pthread_attr_destroy*(a1: var Pthread_attr): cint
  {.importc, header: pthreadh.}
