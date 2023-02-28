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

  template progress*(name: static[string]): untyped =
    {.emit: "COZ_PROGRESS_NAMED($#);" % [ escape(name) ].}

  template transaction*(name: static[string]; body: typed): untyped =
    {.emit: "COZ_BEGIN($#);" % [ escape(name) ].}
    body
    {.emit: "COZ_END($#);" % [ escape(name) ].}
else:
  template progress*(name: static[string]): untyped =
    discard

  template transaction*(name: static[string]; body: typed): untyped =
    body
