import std/os

import insideout/mailboxes
import insideout/valgrind

let N: uint32 =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    1_000_000
  else:
    10_000_000

type RI = ref uint32

proc ri(i: uint32): RI =
  result = new uint32
  result[] = i

proc main =
  ## send a lot of messages
  var box = newMailbox[RI](N)
  for i in 1..N:
    box.send i.ri
  for i in 1..N:
    let message = box.recv
    assert message[] == i

main()
