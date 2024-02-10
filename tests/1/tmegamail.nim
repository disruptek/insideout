import std/os

import insideout/mailboxes
import insideout/valgrind

let N =
  if getEnv"GITHUB_ACTIONS" == "true" or not defined(danger) or isGrinding():
    10_000_000
  else:
    100_000_000

type RI = ref int

proc ri(i: int): RI =
  result = new int
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
