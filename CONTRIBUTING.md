# Contributing to SwapAI

SwapAI manages AI runtimes; it does not implement model inference. Changes
should reinforce that focused role: runtime lifecycle, health, switching,
routing, monitoring, or interoperability.

## Development setup

SwapAI itself requires only a POSIX shell. Clone the repository and run:

```sh
make check
make test
```

The test suite uses temporary configuration and fake runtime adapters. It does
not require Ollama, llama.cpp, vLLM, a GPU, or downloaded model weights.

## Making a change

1. Keep shell code compatible with POSIX `sh`; do not rely on Bash arrays or
   Bash-only conditionals.
2. Add or update a fixture-backed test for behavior changes.
3. Run `make check` and `make test` on your platform.
4. Update `README.md` and `CHANGELOG.md` when user-visible behavior changes.
5. Keep commits focused and explain the user-facing reason for the change.

## Adding a runtime adapter

An adapter should provide the same lifecycle contract as existing backends:

- validate required executables and model configuration;
- start on `SWAPAI_HOST` and `SWAPAI_PORT`;
- remain attached to a single managed PID;
- expose `/v1/models` for deterministic readiness checks;
- accept non-streaming requests at `/v1/chat/completions`;
- stop cleanly on `TERM`;
- write runtime output to the standard SwapAI log;
- fail without replacing a healthy active profile.

Add a fake executable under `tests/fixtures/bin` so CI can verify the adapter
without installing the actual inference engine.

## Reporting problems

Include the output of `swapai doctor`, the relevant profile with secrets or
private paths removed, and the last useful lines from `swapai logs`.
