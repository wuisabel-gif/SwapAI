#!/bin/sh

: "${SWAPAI_VERSION:=0.1.0}"
: "${SWAPAI_HOST:=127.0.0.1}"
: "${SWAPAI_PORT:=11435}"
: "${SWAPAI_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/swapai}"
: "${SWAPAI_STATE_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/swapai}"
: "${SWAPAI_PROFILES:=$SWAPAI_CONFIG_HOME/profiles.tsv}"
: "${SWAPAI_ACTIVE_FILE:=$SWAPAI_STATE_HOME/active}"
: "${SWAPAI_PID_FILE:=$SWAPAI_STATE_HOME/runtime.pid}"
: "${SWAPAI_LOG_FILE:=$SWAPAI_STATE_HOME/runtime.log}"

swapai_info() {
    printf '%s\n' "$*"
}

swapai_error() {
    printf 'swapai: %s\n' "$*" >&2
}

swapai_die() {
    swapai_error "$*"
    return 1
}

swapai_usage() {
    cat <<'EOF'
SwapAI — one command for local AI runtimes

Usage:
  swapai init
  swapai list
  swapai switch <profile>
  swapai status
  swapai stop
  swapai endpoint
  swapai logs [--follow]
  swapai benchmark [prompt]
  swapai doctor
  swapai version

Profiles map a short name such as "coder" to a backend and model.
Supported backends: ollama, llamacpp, vllm, mock.
EOF
}

swapai_ensure_dirs() {
    mkdir -p "$SWAPAI_CONFIG_HOME" "$SWAPAI_STATE_HOME"
}

swapai_init() {
    swapai_ensure_dirs || return 1
    if [ -e "$SWAPAI_PROFILES" ]; then
        swapai_die "profiles already exist at $SWAPAI_PROFILES"
        return 1
    fi
    cp "$SWAPAI_ROOT/examples/profiles.tsv" "$SWAPAI_PROFILES"
    swapai_info "Created $SWAPAI_PROFILES"
    swapai_info "Edit the profiles, then run: swapai switch coder"
}

swapai_require_profiles() {
    if [ ! -f "$SWAPAI_PROFILES" ]; then
        swapai_die "no profiles found; run 'swapai init' first"
        return 1
    fi
}

# Output: name<TAB>backend<TAB>model<TAB>arguments
swapai_profile() {
    profile_name=$1
    swapai_require_profiles || return 1
    awk -F '\t' -v wanted="$profile_name" '
        $0 !~ /^[[:space:]]*#/ && NF >= 3 && $1 == wanted {
            print $0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$SWAPAI_PROFILES"
}

swapai_list() {
    swapai_require_profiles || return 1
    printf '%-16s %-10s %s\n' "PROFILE" "BACKEND" "MODEL"
    awk -F '\t' '
        $0 !~ /^[[:space:]]*#/ && NF >= 3 {
            printf "%-16s %-10s %s\n", $1, $2, $3
        }
    ' "$SWAPAI_PROFILES"
}

swapai_read_pid() {
    [ -f "$SWAPAI_PID_FILE" ] || return 1
    pid=$(sed -n '1p' "$SWAPAI_PID_FILE")
    case $pid in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$pid"
}

swapai_is_running() {
    running_pid=$(swapai_read_pid) || return 1
    kill -0 "$running_pid" 2>/dev/null
}

swapai_write_active() {
    active_name=$1
    active_backend=$2
    active_model=$3
    active_pid=$4
    {
        printf 'name=%s\n' "$active_name"
        printf 'backend=%s\n' "$active_backend"
        printf 'model=%s\n' "$active_model"
        printf 'host=%s\n' "$SWAPAI_HOST"
        printf 'port=%s\n' "$SWAPAI_PORT"
        printf 'pid=%s\n' "$active_pid"
    } > "$SWAPAI_ACTIVE_FILE"
}

swapai_active_value() {
    active_key=$1
    [ -f "$SWAPAI_ACTIVE_FILE" ] || return 1
    sed -n "s/^${active_key}=//p" "$SWAPAI_ACTIVE_FILE" | sed -n '1p'
}

swapai_start_process() {
    : > "$SWAPAI_LOG_FILE"
    nohup "$@" >> "$SWAPAI_LOG_FILE" 2>&1 &
    started_pid=$!
    printf '%s\n' "$started_pid" > "$SWAPAI_PID_FILE"
    sleep 1
    if ! kill -0 "$started_pid" 2>/dev/null; then
        swapai_error "runtime exited during startup"
        sed -n '1,20p' "$SWAPAI_LOG_FILE" >&2
        rm -f "$SWAPAI_PID_FILE"
        return 1
    fi
    printf '%s\n' "$started_pid"
}

swapai_start_backend() {
    backend=$1
    model=$2
    extra_args=${3:-}

    # Profile files are local configuration. Arguments intentionally use shell
    # word splitting, but command substitution and shell operators are never run.
    # shellcheck disable=SC2086
    case $backend in
        ollama)
            command -v ollama >/dev/null 2>&1 || {
                swapai_die "ollama is not installed"
                return 1
            }
            OLLAMA_HOST="$SWAPAI_HOST:$SWAPAI_PORT" \
                swapai_start_process ollama serve
            ;;
        llamacpp)
            llama_bin=${SWAPAI_LLAMA_SERVER:-llama-server}
            command -v "$llama_bin" >/dev/null 2>&1 || {
                swapai_die "llama.cpp server not found: $llama_bin"
                return 1
            }
            swapai_start_process "$llama_bin" -m "$model" \
                --host "$SWAPAI_HOST" --port "$SWAPAI_PORT" $extra_args
            ;;
        vllm)
            python_bin=${SWAPAI_PYTHON:-python3}
            command -v "$python_bin" >/dev/null 2>&1 || {
                swapai_die "python3 is not installed"
                return 1
            }
            swapai_start_process "$python_bin" -m vllm.entrypoints.openai.api_server \
                --model "$model" --host "$SWAPAI_HOST" --port "$SWAPAI_PORT" $extra_args
            ;;
        mock)
            swapai_start_process sh -c 'trap "exit 0" TERM INT; while :; do sleep 1; done'
            ;;
        *)
            swapai_die "unsupported backend '$backend'"
            ;;
    esac
}

swapai_wait_ready() {
    ready_backend=$1
    [ "$ready_backend" = mock ] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    attempt=0
    while [ "$attempt" -lt 30 ]; do
        if curl -fsS --max-time 1 "http://$SWAPAI_HOST:$SWAPAI_PORT/" >/dev/null 2>&1 || \
           curl -fsS --max-time 1 "http://$SWAPAI_HOST:$SWAPAI_PORT/v1/models" >/dev/null 2>&1 || \
           curl -fsS --max-time 1 "http://$SWAPAI_HOST:$SWAPAI_PORT/api/tags" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

swapai_switch() {
    [ "$#" -eq 1 ] || {
        swapai_die "usage: swapai switch <profile>"
        return 1
    }
    requested=$1
    profile=$(swapai_profile "$requested") || {
        swapai_die "unknown profile '$requested'"
        return 1
    }
    old_ifs=$IFS
    IFS="$(printf '\t')"
    set -- $profile
    IFS=$old_ifs
    name=$1
    backend=$2
    model=$3
    arguments=${4:-}

    swapai_ensure_dirs || return 1
    if swapai_is_running; then
        current=$(swapai_active_value name 2>/dev/null || printf 'current runtime')
        swapai_info "Stopping $current..."
        swapai_stop quiet || return 1
    fi

    swapai_info "Starting $name ($backend: $model)..."
    new_pid=$(swapai_start_backend "$backend" "$model" "$arguments") || return 1
    swapai_write_active "$name" "$backend" "$model" "$new_pid"

    if ! swapai_wait_ready "$backend"; then
        swapai_error "runtime did not become ready; see 'swapai logs'"
        swapai_stop quiet >/dev/null 2>&1 || true
        return 1
    fi

    swapai_info "Active: $name"
    swapai_info "Endpoint: http://$SWAPAI_HOST:$SWAPAI_PORT"
    if [ "$backend" = ollama ]; then
        swapai_info "Model will load on its first request: $model"
    fi
}

swapai_stop() {
    stop_mode=${1:-normal}
    if ! stop_pid=$(swapai_read_pid); then
        [ "$stop_mode" = quiet ] || swapai_info "No SwapAI runtime is active."
        rm -f "$SWAPAI_ACTIVE_FILE" "$SWAPAI_PID_FILE"
        return 0
    fi
    recorded_pid=$(swapai_active_value pid 2>/dev/null || true)
    if [ -z "$recorded_pid" ] || [ "$recorded_pid" != "$stop_pid" ]; then
        swapai_error "ignoring stale runtime pid $stop_pid"
        rm -f "$SWAPAI_ACTIVE_FILE" "$SWAPAI_PID_FILE"
        return 1
    fi
    if kill -0 "$stop_pid" 2>/dev/null; then
        kill "$stop_pid" 2>/dev/null || return 1
        sleep 1
        if kill -0 "$stop_pid" 2>/dev/null; then
            kill -KILL "$stop_pid" 2>/dev/null || true
        fi
    fi
    rm -f "$SWAPAI_ACTIVE_FILE" "$SWAPAI_PID_FILE"
    [ "$stop_mode" = quiet ] || swapai_info "Stopped SwapAI runtime."
}

swapai_status() {
    if ! swapai_is_running; then
        swapai_info "Status: stopped"
        return 1
    fi
    swapai_info "Status: running"
    swapai_info "Profile: $(swapai_active_value name)"
    swapai_info "Backend: $(swapai_active_value backend)"
    swapai_info "Model: $(swapai_active_value model)"
    swapai_info "PID: $(swapai_read_pid)"
    swapai_info "Endpoint: http://$SWAPAI_HOST:$SWAPAI_PORT"
}

swapai_endpoint() {
    printf 'http://%s:%s\n' "$SWAPAI_HOST" "$SWAPAI_PORT"
}

swapai_logs() {
    [ -f "$SWAPAI_LOG_FILE" ] || {
        swapai_die "no runtime log found"
        return 1
    }
    case ${1:-} in
        --follow|-f) tail -f "$SWAPAI_LOG_FILE" ;;
        '') tail -n 100 "$SWAPAI_LOG_FILE" ;;
        *) swapai_die "usage: swapai logs [--follow]" ;;
    esac
}

swapai_benchmark() {
    swapai_is_running || {
        swapai_die "no runtime is active"
        return 1
    }
    command -v curl >/dev/null 2>&1 || {
        swapai_die "curl is required for benchmarks"
        return 1
    }
    bench_backend=$(swapai_active_value backend)
    bench_model=$(swapai_active_value model)
    [ "$bench_backend" != mock ] || {
        swapai_die "the mock backend does not serve inference requests"
        return 1
    }
    bench_prompt=${*:-Reply with exactly: ready}
    escaped_prompt=$(printf '%s' "$bench_prompt" | sed 's/\\/\\\\/g; s/"/\\"/g')
    escaped_model=$(printf '%s' "$bench_model" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if [ "$bench_backend" = ollama ]; then
        bench_url="http://$SWAPAI_HOST:$SWAPAI_PORT/api/generate"
        bench_data="{\"model\":\"$escaped_model\",\"prompt\":\"$escaped_prompt\",\"stream\":false}"
    else
        bench_url="http://$SWAPAI_HOST:$SWAPAI_PORT/v1/chat/completions"
        bench_data="{\"model\":\"$escaped_model\",\"messages\":[{\"role\":\"user\",\"content\":\"$escaped_prompt\"}],\"stream\":false}"
    fi
    result=$(curl -fsS -o "$SWAPAI_STATE_HOME/benchmark.json" \
        -w '%{time_total}' -H 'Content-Type: application/json' \
        -d "$bench_data" "$bench_url") || {
        swapai_die "benchmark request failed"
        return 1
    }
    swapai_info "Model: $bench_model"
    swapai_info "Backend: $bench_backend"
    swapai_info "Total time: ${result}s"
    swapai_info "Response: $SWAPAI_STATE_HOME/benchmark.json"
}

swapai_doctor_line() {
    doctor_label=$1
    doctor_command=$2
    if command -v "$doctor_command" >/dev/null 2>&1; then
        printf '  [ok]      %-12s %s\n' "$doctor_label" "$(command -v "$doctor_command")"
    else
        printf '  [missing] %-12s %s\n' "$doctor_label" "$doctor_command"
    fi
}

swapai_doctor() {
    swapai_info "SwapAI $SWAPAI_VERSION"
    swapai_info "Configuration: $SWAPAI_PROFILES"
    swapai_info "State: $SWAPAI_STATE_HOME"
    swapai_info "Endpoint: http://$SWAPAI_HOST:$SWAPAI_PORT"
    swapai_info "Tools:"
    swapai_doctor_line curl curl
    swapai_doctor_line Ollama ollama
    swapai_doctor_line llama.cpp "${SWAPAI_LLAMA_SERVER:-llama-server}"
    swapai_doctor_line Python "${SWAPAI_PYTHON:-python3}"
    if "${SWAPAI_PYTHON:-python3}" -c 'import vllm' >/dev/null 2>&1; then
        printf '  [ok]      %-12s %s\n' "vLLM" "Python package"
    else
        printf '  [missing] %-12s %s\n' "vLLM" "Python package"
    fi
}

swapai_main() {
    command_name=${1:-help}
    [ "$#" -eq 0 ] || shift
    case $command_name in
        init) swapai_init "$@" ;;
        list|ls) swapai_list "$@" ;;
        switch|use) swapai_switch "$@" ;;
        status) swapai_status "$@" ;;
        stop) swapai_stop "$@" ;;
        endpoint) swapai_endpoint "$@" ;;
        logs) swapai_logs "$@" ;;
        benchmark|bench) swapai_benchmark "$@" ;;
        doctor) swapai_doctor "$@" ;;
        version|--version|-V) swapai_info "swapai $SWAPAI_VERSION" ;;
        help|--help|-h) swapai_usage ;;
        *)
            swapai_error "unknown command '$command_name'"
            swapai_usage >&2
            return 1
            ;;
    esac
}
