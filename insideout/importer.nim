import std/macros

export newLit

proc importPragmaExpr(expr: NimNode; header: NimNode;
                      csym: NimNode = nil): NimNode =
  var p = nnkPragma.newTree()
  if csym.isNil or csym.kind in {nnkEmpty, nnkNilLit}:
    p.add ident"importc"
  else:
    p.add nnkExprColonExpr.newTree(ident"importc", csym)
  p.add nnkExprColonExpr.newTree(ident"header", header)
  case expr.kind
  of nnkPragmaExpr:
    result = nnkPragmaExpr.newTree(expr[0], p)  # unwrap pragmaexpr
  of nnkPostfix, nnkIdent, nnkSym:
    result = nnkPragmaExpr.newTree(expr, p)     # no pragmaexpr
  else:
    error "unsupported form"

proc importer*(n: NimNode; header: NimNode; csym: NimNode = nil): NimNode =
  ## whatfer making little macros that turn
  ##   `let xY {.threadsh: "A_B"}: cint`
  ## into
  ##   `let xY {.importc: "A_B", header: "<some/threads.h>".}: cint`
  case n.kind
  of nnkLetSection, nnkVarSection:
    let pe = importPragmaExpr(n[0][0], header, csym)
    result = n.kind.newTree: newIdentDefs(pe, n[0][1], n[0][2])
  of nnkTypeDef:
    let pe = importPragmaExpr(n[0], header, csym)
    result = n.kind.newTree(pe, n[1], n[2])
  of nnkProcDef:
    let pe = importPragmaExpr(n[0], header, csym)
    result = newTree n.kind
    var p = copyNimTree n[4]
    for n in pe[1].items:
      p.add n  # add in our Pragma(s)
    for i in 0..<n.len:
      result.add(if 4 == i: p else: n[i])  # swap in the new Pragmas
  else:
    echo treeRepr(n)
    error $n.kind & " not yet supported by importer"
