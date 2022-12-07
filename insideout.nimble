version = "0.0.1"
author = "disruptek"
description = "insideout"
license = "MIT"

requires "https://github.com/nim-works/cps >= 0.7.0 & < 1.0.0"
requires "https://github.com/disruptek/balls >= 3.9.0 & < 4.0.0"

task test, "run tests for ci":
  when defined(windows):
    exec "balls.cmd --backend:c --mm:arc --mm:orc"
  else:
    exec "balls --backend:c --mm:arc --mm:orc"
