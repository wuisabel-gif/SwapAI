# Changelog

All notable changes to SwapAI will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Exact model-to-profile switching with `switch --for-model`.
- Safe profile creation with `swapai add` and line-specific TSV diagnostics.
- Ollama attach mode for reusing an existing external daemon.
- Benchmark completion-token throughput and streaming time-to-first-token.
- Cross-shell test execution, mandatory CI ShellCheck, and README status badges.
- Session-scoped commands with automatic runtime restoration via `swapai run`.
- Configurable graceful shutdown and post-stop NVIDIA process diagnostics.
- Doctor warnings for native Ollama and unowned SwapAI port collisions.

### Changed

- Ollama attach mode now unloads its pinned model when detaching by default;
  `SWAPAI_ATTACH_UNLOAD=0` keeps the model warm.
- The default benchmark prompt requests a meaningful generation window instead
  of a two-to-four-token response.
- Installer version tests now derive their expectation from the program's
  version declaration.

### Planned

- Persistent benchmark history and comparisons.
- Warm-model pools and policy-based routing.
- Optional translation for backend-specific API differences.

## 0.2.0 - 2026-07-21

### Added

- One `/v1` base URL across Ollama, llama.cpp, and vLLM.
- `swapai model` for active-model discovery.
- `swapai chat` for direct OpenAI-compatible requests.

### Changed

- Runtime readiness now verifies the standard `/v1/models` endpoint.
- Benchmarks now use `/v1/chat/completions` for every production backend.
- `swapai endpoint` now returns the client-ready `/v1` URL.

## 0.1.0 - 2026-07-21

### Added

- Shell-first `swapai` CLI.
- Profile-based switching across Ollama, llama.cpp, and vLLM.
- Stable configurable host and port.
- Runtime status, stop, logs, diagnostics, and benchmarking commands.
- Backend-specific health checks and Ollama model preloading.
- Failure-safe switching with automatic rollback.
- Self-contained installer and isolated mock/adapter test suite.
