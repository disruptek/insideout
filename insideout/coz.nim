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
  {.passC: "-include coz.h".}
  {.passL: "-ldl".}

  proc emitCoz(name: string; s: string): NimNode =
    var s = "$#($#);" % [ name, escape(s) ]
    nnkPragma.newTree:
      nnkExprColonExpr.newTree:
        [ident"emit", nnkBracket.newTree s.newLit]

  macro progress*(name: static[string]): untyped =
    emitCoz("COZ_PROGRESS_NAMED", name)

  macro transaction*(name: static[string]; body: typed): untyped =
    result = newStmtList()
    result.add:
      emitCoz("COZ_BEGIN", name)
    result.add:
      nnkDefer.newTree:
        emitCoz("COZ_END", name)
    result.add:
      body

else:
  template progress*(name: static[string]): untyped =
    discard

  template transaction*(name: static[string]; body: typed): untyped =
    body
