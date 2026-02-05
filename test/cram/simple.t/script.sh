#!/bin/bash

export OCAMLRUNPARAM=b
export JS_TOP_WORKER_SOCK="/tmp/js_top_worker_simple_$$.sock"

cleanup() {
    [ -n "$WORKER_PID" ] && kill "$WORKER_PID" 2>/dev/null
    rm -f "$JS_TOP_WORKER_SOCK"
}
trap cleanup EXIT

rm -f "$JS_TOP_WORKER_SOCK"

# Worker prints child PID and only returns once ready
WORKER_PID=$(unix_worker)

unix_client init '{ findlib_requires:[], execute: true }'
unix_client setup ''
unix_client exec_toplevel '' '# Printf.printf "Hello, world\n";;'
unix_client exec_toplevel '' "$(cat s1)"
unix_client exec_toplevel '' "$(cat s2)"
