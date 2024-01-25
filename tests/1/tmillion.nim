import pkg/insideout/mailboxes

type
  RI = ref int

proc `==`(a: RI; b: int): bool = a[] == b
proc `==`(a, b: RI): bool =
  (a.isNil and b.isNil) or (not a.isNil and not b.isNil and a[] == b[])
proc `$`(ri: RI): string {.used.} = $ri[]
proc ri(s: int): RI =
  result = new int
  result[] = s

proc check(expr: bool; s: string) =
  if expr:
    debugEcho s
  else:
    raise AssertionError.newException "rip"

template check(expr: untyped): untyped =
  check(expr, "ok")

proc main =
  var receipt: RI
  block:
    ## send a million messages
    const N = 1_000_000
    var box = newMailbox[RI](N)
    for i in 0 ..< N:
      box.send i.ri
    for i in 0 ..< N:
      let message = box.recv
      check message == i.ri

when isMainModule:
  main()
