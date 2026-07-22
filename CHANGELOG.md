# Changelog

All notable changes to SwapAI will be documented in this file.

The project follows [Semantic Versioning](https://semver.org/).

## Unreleased

### Planned

- A backend-independent OpenAI-compatible proxy.
- Persistent benchmark history and comparisons.
- Warm-model pools and policy-based routing.

## 0.1.0 - 2026-07-21

### Added

- Shell-first `swapai` CLI.
- Profile-based switching across Ollama, llama.cpp, and vLLM.
- Stable configurable host and port.
- Runtime status, stop, logs, diagnostics, and benchmarking commands.
- Backend-specific health checks and Ollama model preloading.
- Failure-safe switching with automatic rollback.
- Self-contained installer and isolated mock/adapter test suite.
