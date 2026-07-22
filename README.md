# SwapAI

SwapAI is a shell-first control plane for local AI inference. It gives Ollama,
llama.cpp, and vLLM one small command-line interface and one predictable local
endpoint.

```text
Your editor / app / agent
          |
          | http://127.0.0.1:11435
          v
       SwapAI
       /  |  \
  Ollama vLLM llama.cpp
       \  |  /
   Llama, Qwen, Gemma, Mistral, Phi, DeepSeek, ...
```

SwapAI is an orchestrator, not an inference engine. The selected backend still
does the model computation.

## Quick start

Requirements: a POSIX shell and at least one supported runtime. `curl` is used
for readiness checks and benchmarks.

```sh
./install.sh
swapai init
${EDITOR:-vi} "$HOME/.config/swapai/profiles.tsv"
swapai switch coder
swapai status
```

By default SwapAI listens at `http://127.0.0.1:11435`. Point an
OpenAI-compatible client at `/v1` when using llama.cpp or vLLM. Ollama retains
its native endpoints, such as `/api/generate`, on the same host and port.

## Commands

```text
swapai init                 Create the user profile file
swapai list                 List configured profiles
swapai switch <profile>     Stop the current runtime and start another
swapai status               Show the active profile, backend, model, and PID
swapai stop                 Gracefully stop the managed runtime
swapai endpoint             Print the stable base URL
swapai logs [--follow]      Read or follow runtime logs
swapai benchmark [prompt]   Time one non-streaming inference request
swapai doctor               Check runtime and tool availability
```

`use`, `ls`, and `bench` are short aliases for `switch`, `list`, and
`benchmark`.

Switches are failure-safe: if a replacement runtime cannot start or become
healthy, SwapAI attempts to restore the previously active profile. It also
reports an occupied endpoint port before attempting startup.

Before stopping the current runtime, SwapAI validates the replacement's
executable and local model path where possible. Unsupported or incomplete
profiles therefore leave the active runtime untouched.

## Profiles

Profiles are tab-separated and live at
`~/.config/swapai/profiles.tsv` by default:

```tsv
# name  backend   model                         optional arguments
coder  ollama    qwen2.5-coder:7b
chat   ollama    llama3.2:3b
gguf   llamacpp  /models/qwen-coder.gguf       --ctx-size 8192 --n-gpu-layers 99
serve  vllm      Qwen/Qwen2.5-7B-Instruct      --dtype auto
```

The separators must be literal tab characters. Supported backend values are:

- `ollama`: starts a dedicated `ollama serve` process on the SwapAI endpoint.
- `llamacpp`: runs `llama-server`; the model field is a GGUF path.
- `vllm`: runs the vLLM OpenAI-compatible server through Python.
- `mock`: lifecycle-only backend used by the test suite.

For Ollama, a switch verifies that the configured model is installed and loads
it before reporting the profile as active. Pull it before switching if needed:

```sh
ollama pull qwen2.5-coder:7b
```

## Configuration

Environment variables make SwapAI easy to script and test:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SWAPAI_HOST` | `127.0.0.1` | Runtime bind host |
| `SWAPAI_PORT` | `11435` | Stable runtime port |
| `SWAPAI_CONFIG_HOME` | `$XDG_CONFIG_HOME/swapai` | Configuration directory |
| `SWAPAI_STATE_HOME` | `$XDG_STATE_HOME/swapai` | PID, active state, logs |
| `SWAPAI_LLAMA_SERVER` | `llama-server` | llama.cpp server executable |
| `SWAPAI_PYTHON` | `python3` | Python used to start vLLM |
| `SWAPAI_START_TIMEOUT` | `120` | Seconds allowed for runtime startup |
| `SWAPAI_MODEL_TIMEOUT` | `300` | Seconds allowed for Ollama model loading |

The installer accepts `SWAPAI_INSTALL_DIR` for the executable directory and
`SWAPAI_SHARE_DIR` for the self-contained program files.

SwapAI owns the process on its configured port. If another service already uses
that port, choose another with `SWAPAI_PORT`.

## Development

No language runtime or package manager is required for SwapAI itself.

```sh
make check
make test
```

The tests isolate all configuration and state in a temporary directory and use
fixture adapters, so they do not download a model or require a GPU. CI runs the
same checks on both macOS and Linux. See [CONTRIBUTING.md](CONTRIBUTING.md) for
adapter requirements and contribution guidance.

Release history is recorded in [CHANGELOG.md](CHANGELOG.md).

## Current scope

This first version intentionally focuses on deterministic local switching. A
future daemon or proxy could add zero-downtime warm pools, request routing,
fallbacks, and one OpenAI-compatible API across every backend. Today, switching
is stop-then-start, and the endpoint stays stable while its backend-native API
shape may differ.

## License

MIT
