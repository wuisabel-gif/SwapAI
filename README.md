# SwapAI

[![CI](https://github.com/wuisabel-gif/SwapAI/actions/workflows/ci.yml/badge.svg)](https://github.com/wuisabel-gif/SwapAI/actions/workflows/ci.yml)
[![ShellCheck](https://github.com/wuisabel-gif/SwapAI/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/wuisabel-gif/SwapAI/actions/workflows/shellcheck.yml)

SwapAI is a shell-first orchestrator for local AI runtimes. It gives Ollama,
llama.cpp, and vLLM one command-line interface and one predictable
OpenAI-compatible API.

The CLI is POSIX shell, requires no language runtime or package manager, and is
covered by isolated mock-runtime tests on macOS and Linux. CI exercises the
suite through `sh`, `bash`, and `dash` where available and runs ShellCheck.

```text
Your editor / app / agent
          |
          | http://127.0.0.1:11435/v1
          v
       SwapAI
       /  |  \
  Ollama vLLM llama.cpp
       \  |  /
   Llama, Qwen, Gemma, Mistral, Phi, DeepSeek, ...
```

SwapAI is an orchestrator, not an inference engine. The selected backend still
does the model computation.

## Why bother?

Local AI runtimes disagree on startup commands, model arguments, ports,
readiness checks, and shutdown behavior. Switching by hand means remembering
each backend's details, reconfiguring clients, and cleaning up processes that
may still hold GPU memory.

SwapAI turns that work into one explicit, failure-safe operation:

1. Validate the requested profile before disturbing the active runtime.
2. Stop the managed process gracefully and check for resource conflicts.
3. Start the selected backend on a predictable OpenAI-compatible endpoint.
4. Verify readiness and, for Ollama, confirm that the model is installed and
   loaded.
5. Restore the previous profile automatically if the replacement fails.

It can also scope a runtime to one command with `swapai run`, or resolve an
exact model ID with `swapai switch --for-model`. SwapAI never performs inference
or stays in the request path; it makes local runtime lifecycle changes visible,
repeatable, and easy to audit. The complete control layer is currently 927
lines of POSIX shell in [`lib/swapai.sh`](lib/swapai.sh).

## Quick start

Requirements: a POSIX shell and at least one supported runtime. `curl` is used
for readiness checks and benchmarks.

```sh
./install.sh
swapai init
${EDITOR:-vi} "$HOME/.config/swapai/profiles.tsv"
swapai switch coder
swapai status
swapai endpoint
swapai model
swapai chat "Explain this code"
```

By default, every supported runtime exposes its OpenAI-compatible API at
`http://127.0.0.1:11435/v1`. Applications can keep one base URL while SwapAI
changes the runtime behind it. The active model name is available from
`swapai model` or the standard `/v1/models` endpoint.

Ollama, llama.cpp, and vLLM each implement `/v1/models` and
`/v1/chat/completions`. Their backend-native endpoints remain available on the
same host and port when advanced runtime-specific behavior is needed.

## Commands

```text
swapai init                 Create the user profile file
swapai add NAME BACKEND MODEL [ARGS...]
                            Add a profile without editing TSV
swapai list                 List configured profiles
swapai switch <profile>     Stop the current runtime and start another
swapai switch --for-model MODEL
                            Resolve an exact model name to a profile and switch
swapai run PROFILE -- COMMAND...
                            Run a command in a temporary runtime session
swapai status               Show the active profile, backend, model, and PID
swapai stop                 Gracefully stop the managed runtime
swapai endpoint             Print the OpenAI-compatible /v1 base URL
swapai model                Print the active model identifier
swapai chat [prompt]         Send one OpenAI-compatible chat request
swapai logs [--follow]      Read or follow runtime logs
swapai benchmark [prompt]   Measure latency, TTFT, and output throughput
swapai doctor               Check runtime and tool availability
```

`use`, `ls`, and `bench` are short aliases for `switch`, `list`, and
`benchmark`. Both `chat` and `benchmark` use the same
`/v1/chat/completions` contract across every production backend.

`swapai run` scopes a runtime switch to one command. It restores the previous
profile afterward—even when the command fails or receives an interrupt—and
stops the temporary runtime when no profile was previously active:

```sh
swapai run coder -- ./run-evaluation.sh
```

`benchmark` makes one non-streaming request for a complete response and one
streaming request for time-to-first-token. It reports `completion_tokens`,
estimated generation time, and tokens per second. The streaming response and
the normal JSON response are retained in the state directory for inspection.

Switches are failure-safe: if a replacement runtime cannot start or become
healthy, SwapAI attempts to restore the previously active profile. It also
reports an occupied endpoint port before attempting startup.

Managed runtimes receive `TERM` and up to 15 seconds to shut down before
SwapAI sends `KILL`, avoiding premature termination while vLLM releases GPU
resources. When `nvidia-smi` is available, SwapAI warns if the stopped runtime
PID is still reported as a compute process; this diagnostic never blocks the
next operation.

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

The separators must be literal tab characters. `swapai doctor` reports the
exact line number when a profile uses spaces instead, and `swapai add` avoids
manual TSV editing for the common case:

```sh
swapai add coder ollama qwen2.5-coder:7b
swapai add gguf llamacpp /models/qwen.gguf --ctx-size 8192
```

Agents can request a configured model without knowing its profile alias:

```sh
swapai switch --for-model qwen2.5-coder:7b
```

The first exact model match wins. Supported backend values are:

- `ollama`: starts a dedicated `ollama serve` process on the SwapAI endpoint.
- `ollama-attach`: reuses an existing Ollama service instead of owning a
  second daemon.
- `llamacpp`: runs `llama-server`; the model field is a GGUF path.
- `vllm`: runs the vLLM OpenAI-compatible server through Python.
- `mock`: lifecycle-only backend used by the test suite.

For Ollama, a switch verifies that the configured model is installed and loads
it before reporting the profile as active. Pull it before switching if needed:

```sh
ollama pull qwen2.5-coder:7b
```

### Existing Ollama services

Desktop and package-manager installations commonly keep `ollama serve`
running on port `11434`. Starting another Ollama daemon on `11435` can make two
processes compete for the same model store and accelerator memory. Use an
`ollama-attach` profile to reuse the existing service:

```sh
swapai add existing ollama-attach qwen2.5-coder:7b
swapai switch existing
```

Attach mode verifies and loads the configured model but never stops the
external Ollama process. By default, `swapai stop` unloads the model that
SwapAI pinned in the external daemon before detaching. Set
`SWAPAI_ATTACH_UNLOAD=0` if that model should remain warm. The API endpoint is
`http://127.0.0.1:11434/v1` by default, so clients must use the endpoint printed
by `swapai endpoint`. Set `SWAPAI_OLLAMA_PORT` if the existing service uses
another port.

`swapai doctor` checks both the native Ollama port and SwapAI's configured
endpoint. It warns when a native daemon could compete with a separately managed
Ollama process, or when the SwapAI port belongs to an untracked process.

## Configuration

Environment variables make SwapAI easy to script and test:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SWAPAI_HOST` | `127.0.0.1` | Runtime bind host |
| `SWAPAI_PORT` | `11435` | Stable runtime port |
| `SWAPAI_OLLAMA_PORT` | `11434` | Existing Ollama port used by attach mode |
| `SWAPAI_CONFIG_HOME` | `$XDG_CONFIG_HOME/swapai` | Configuration directory |
| `SWAPAI_STATE_HOME` | `$XDG_STATE_HOME/swapai` | PID, active state, logs |
| `SWAPAI_LLAMA_SERVER` | `llama-server` | llama.cpp server executable |
| `SWAPAI_PYTHON` | `python3` | Python used to start vLLM |
| `SWAPAI_START_TIMEOUT` | `120` | Seconds allowed for runtime startup |
| `SWAPAI_MODEL_TIMEOUT` | `300` | Seconds allowed for Ollama model loading |
| `SWAPAI_STOP_TIMEOUT` | `15` | Grace period before a managed runtime is killed |
| `SWAPAI_ATTACH_UNLOAD` | `1` | Unload an attached Ollama model when detaching (`0` keeps it warm) |

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
fixture adapters, so they do not download a model or require a GPU. `make test`
runs them through every available POSIX-target shell among `sh`, `bash`, and
`dash`; `make check` includes ShellCheck when installed. CI enforces both on
macOS and Linux. See [CONTRIBUTING.md](CONTRIBUTING.md) for adapter requirements
and contribution guidance.

Release history is recorded in [CHANGELOG.md](CHANGELOG.md).

## Current scope

SwapAI currently standardizes the OpenAI Chat Completions and Models endpoints.
Individual runtimes may support different optional OpenAI fields and additional
native APIs. A future translation proxy could normalize those differences,
provide stable model aliases, and add request routing or fallbacks. Switching
remains stop-then-start with automatic rollback when the replacement fails.

## License

MIT
