# Changelog

All notable changes to SwapAI will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/).

## Unreleased

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
