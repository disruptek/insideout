import std/genasts
import std/macros
import std/options
import std/strutils

when compileOption"debuginfo":
  const
    insideoutCoz* {.booldefine.} = false
else:
  const
    insideoutCoz* = false

when insideoutCoz:
  {.passC: "-gdwarf-3".}
  {.passL: "-gdwarf-3 -ldl".}

  proc progress*(name: cstring)
    {.importc: "COZ_PROGRESS_NAMED", header: "<coz.h>".}

  proc progress*()
    {.importc: "COZ_PROGRESS", header: "<coz.h>".}

  proc COZ_BEGIN(name: cstring) {.importc, header: "<coz.h>".}
  proc COZ_END(name: cstring) {.importc, header: "<coz.h>".}

  macro transaction*(name: static[string]; body: typed): untyped =
    result = newStmtList()
    result.add:
      newCall(bindSym"COZ_BEGIN", name.newLit)
    result.add:
      nnkDefer.newTree:
        newCall(bindSym"COZ_END", name.newLit)
    result.add:
      body

else:
  template progress*(): untyped = discard
  template progress*(name: cstring): untyped = discard
  template transaction*(name: cstring; body: typed): untyped = body
