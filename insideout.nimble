version = "0.0.1"
author = "disruptek"
description = "insideout"
license = "MIT"

requires "https://github.com/nim-works/cps >= 0.7.0 & < 1.0.0"
requires "https://github.com/zevv/nimactors >= 0.0.1 & < 1.0.0"

task test, "run tests for ci":
  when defined(windows):
    exec "balls.cmd --gc:arc --gc:orc"
  else:
    exec "balls --gc:arc --gc:orc"
