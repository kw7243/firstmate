#!/usr/bin/env bash
ulimit -c 0
exec env TMPDIR=/tmp "/home/ubuntu/.no-mistakes/worktrees/9c45ef16ef2c/01M3WKBBGW6603Q1A28DA55CZQ/.calm-validation/browser/chrome/linux-154.0.8037.92/chrome-linux64/chrome" "$@"
