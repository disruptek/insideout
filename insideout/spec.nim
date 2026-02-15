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
    try:
      stdmsg().writeLine $getThreadId() & " " & args.join("")
    except IOError:
      discard
else:
  template debug*(args: varargs[untyped]) = discard

import pkg/cps

proc coop*(a: sink Continuation): Continuation {.cpsMagic.} =
  ## yield to the dispatcher
  a

const
  NormalCallNodes = CallNodes - {nnkHiddenCallConv}

proc errorAst(s: string, info: NimNode = nil): NimNode =
  ## Produce {.error: s.} in order to embed errors in the AST
  result = newTree(nnkPragma,
                   ident("error").newColonExpr(newLit s))
  if not info.isNil:
    result[0].copyLineInfo info

proc errorAst(n: NimNode; s = "creepy ast"): NimNode =
  ## Embed an error with a message; line info is copied from the node
  errorAst(s & ":\n" & treeRepr(n) & "\n", n)

proc pragmaArgument(n: NimNode; s: string): NimNode =
  ## from foo() or proc foo() {.some: Pragma.}, retrieve Pragma
  case n.kind
  of nnkProcDef:
    let p = n
    for n in p.pragma.items:
      case n.kind
      of nnkExprColonExpr:
        if $n[0] == s:
          if result.isNil:
            result = n[1]
          else:
            result = n.errorAst "redundant " & s & " pragmas?"
      else:
        discard
    if result.isNil:
      result = n.errorAst "failed to find expected " & s & " form"
  of NormalCallNodes:
    result = pragmaArgument(n.name.getImpl, s)
  else:
    result = n.errorAst "unsupported pragmaArgument target: " & $n.kind

macro `{}`*(s: typed; field: untyped): untyped =
  (getImpl s).pragmaArgument(field.strVal)
