#!/bin/bash
# Start the worker - it prints child PID and only returns once ready

if [ -z "$JS_TOP_WORKER_SOCK" ]; then
    echo "ERROR: JS_TOP_WORKER_SOCK not set" >&2
    exit 1
fi

rm -f "$JS_TOP_WORKER_SOCK"
unix_worker
