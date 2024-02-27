import std/macros

when not defined(isNimSkull):
  when (NimMajor, NimMinor) < (1, 7):
    {.error: "insideout requires nimskull, or old nim >= 1.7".}

when not (defined(gcArc) or defined(gcOrc)):
  {.error: "insideout requires arc or orc memory management".}

when not defined(useMalloc):
  {.error: "insideout requires define:useMalloc".}

when not (defined(c) or defined(cpp)):
  {.error: "insideout requires backend:c or backend:cpp".}

when not (defined(posix) and compileOption"threads"):
  {.error: "insideout requires POSIX threads".}

const insideoutSafeMode* {.booldefine.} = not (compiles do: import loony)
const insideoutGratuitous* {.booldefine.} = false

when insideoutGratuitous:
  import std/strutils
  template debug*(args: varargs[string, `$`]) =
    stdmsg().writeLine $getThreadId() & " " & args.join("")
else:
  template debug*(args: varargs[untyped]) = discard

import pkg/cps
from pkg/cps/spec import pragmaArgument
from pkg/cps/normalizedast import NormNode

proc coop*(a: sink Continuation): Continuation {.cpsMagic.} =
  ## yield to the dispatcher
  a

macro `{}`*(s: typed; field: untyped): untyped =
  (getImpl s).NormNode.pragmaArgument(field.strVal)
