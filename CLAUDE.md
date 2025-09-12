# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an OCaml toplevel (REPL) designed to run in a web worker. The project consists of multiple OPAM packages that work together to provide an OCaml interactive environment in the browser.

## Build Commands

```bash
# Build the entire project
dune build

# Run tests
dune runtest

# Build and watch for changes
dune build --watch

# Run a specific test
dune test test/cram
```

## Running the Example

The worker needs to be served by an HTTP server rather than loaded from the filesystem:

```bash
dune build
cd _build/default/example
python3 -m http.server 8000
# Then open http://localhost:8000/
```

## Architecture

The codebase is organized into several interconnected packages:

- **js_top_worker**: Core library implementing the OCaml toplevel functionality
- **js_top_worker-web**: Web-specific worker implementation with browser integration
- **js_top_worker-client**: Client library for communicating with the worker (Lwt-based)
- **js_top_worker-client_fut**: Alternative client library using Fut for concurrency
- **js_top_worker-rpc**: RPC definitions and communication layer
- **js_top_worker-unix**: Unix implementation for testing outside the browser
- **js_top_worker-bin**: Command-line tools including `jtw` for package management

Key directories:
- `lib/`: Core toplevel implementation with OCaml compiler integration
- `idl/`: RPC interface definitions using `ppx_deriving_rpc`
- `example/`: Example applications demonstrating worker usage
- `bin/`: Command-line tools, notably `jtw` for OPAM package handling

The system uses RPC (via `rpclib`) for communication between the client and worker, with support for both browser WebWorkers and Unix sockets for testing.