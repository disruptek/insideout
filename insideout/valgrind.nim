import std/compilesettings
import std/genasts
import std/macros
import std/options
import std/strutils

const
  insideoutValgrind* {.booldefine.} = false

when insideoutValgrind:
  {.passC: "-include valgrind/valgrind.h".}
  {.passC: "-include valgrind/helgrind.h".}

macro whenValgrind(tmplate: typed): untyped =
  tmplate.expectKind nnkTemplateDef
  var tmplate = copyNimTree tmplate
  while tmplate.len > 7: tmplate.del 7
  tmplate.body =
    genAstOpt({}, condition=insideoutValgrind, logic=tmplate.body):
      when condition:
        logic
  result = tmplate

template happensBefore*(x: pointer): untyped {.whenValgrind.} =
  block:
    let y {.exportc, inject.} = x
    {.emit: "ANNOTATE_HAPPENS_BEFORE(y);".}

template happensAfter*(x: pointer): untyped {.whenValgrind.} =
  block:
    let y {.exportc, inject.} = x
    {.emit: "ANNOTATE_HAPPENS_AFTER(y);".}

template happensBeforeForgetAll*(x: pointer): untyped {.whenValgrind.} =
  block:
    let y {.exportc, inject.} = x
    {.emit: "ANNOTATE_HAPPENS_BEFORE_FORGET_ALL(y);".}

var runningOnValgrind: Option[bool]
proc isUnderValgrind*(): bool =
  ## truthy if we're running the application under valgrind
  if runningOnValgrind.isNone:
    when insideoutValgrind:
      {.emit: "result = RUNNING_ON_VALGRIND;".}
    runningOnValgrind = some result
  get runningOnValgrind

const runningSanitizer =
  some:
    "-fsanitize=" in querySetting(SingleValueSetting.commandLine)
proc isSanitizing*(): bool =
  get runningSanitizer

template isGrinding*(): bool =
  isUnderValgrind() or isSanitizing()
