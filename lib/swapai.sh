#!/bin/sh

SWAPAI_ROOT=${SWAPAI_ROOT:?SWAPAI_ROOT must point to the SwapAI installation}

: "${SWAPAI_VERSION:=0.2.0}"
: "${SWAPAI_HOST:=127.0.0.1}"
: "${SWAPAI_PORT:=11435}"
: "${SWAPAI_OLLAMA_PORT:=11434}"
: "${SWAPAI_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/swapai}"
: "${SWAPAI_STATE_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/swapai}"
: "${SWAPAI_PROFILES:=$SWAPAI_CONFIG_HOME/profiles.tsv}"
: "${SWAPAI_ACTIVE_FILE:=$SWAPAI_STATE_HOME/active}"
: "${SWAPAI_PID_FILE:=$SWAPAI_STATE_HOME/runtime.pid}"
: "${SWAPAI_LOG_FILE:=$SWAPAI_STATE_HOME/runtime.log}"
: "${SWAPAI_START_TIMEOUT:=120}"
: "${SWAPAI_MODEL_TIMEOUT:=300}"

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
  swapai add <profile> <backend> <model> [arguments...]
  swapai list
  swapai switch <profile>
  swapai switch --for-model <model>
  swapai status
  swapai stop
  swapai endpoint
  swapai model
  swapai chat [prompt]
  swapai logs [--follow]
  swapai benchmark [prompt]
  swapai doctor
  swapai version

Profiles map a short name such as "coder" to a backend and model.
Supported backends: ollama, ollama-attach, llamacpp, vllm, mock.
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

swapai_profile_for_model() {
    profile_model=$1
    swapai_require_profiles || return 1
    awk -F '\t' -v wanted="$profile_model" '
        $0 !~ /^[[:space:]]*#/ && NF >= 3 && $3 == wanted {
            print $0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$SWAPAI_PROFILES"
}

swapai_add() {
    [ "$#" -ge 3 ] || {
        swapai_die "usage: swapai add <profile> <backend> <model> [arguments...]"
        return 1
    }
    added_name=$1
    added_backend=$2
    added_model=$3
    shift 3
    added_arguments=$*

    case $added_name in
        ''|*[!A-Za-z0-9_.-]*)
            swapai_die "profile names may contain only letters, numbers, '.', '_', and '-'"
            return 1
            ;;
    esac
    case $added_backend in
        ollama|ollama-attach|llamacpp|vllm|mock) ;;
        *)
            swapai_die "unsupported backend '$added_backend'"
            return 1
            ;;
    esac
    case $added_model in
        ''|*[[:space:]]*)
            swapai_die "model must be a non-empty value without whitespace"
            return 1
            ;;
    esac

    swapai_ensure_dirs || return 1
    if [ ! -f "$SWAPAI_PROFILES" ]; then
        printf '# name<TAB>backend<TAB>model<TAB>optional runtime arguments\n' > "$SWAPAI_PROFILES"
    elif swapai_profile "$added_name" >/dev/null 2>&1; then
        swapai_die "profile '$added_name' already exists"
        return 1
    fi

    if [ -n "$added_arguments" ]; then
        printf '%s\t%s\t%s\t%s\n' \
            "$added_name" "$added_backend" "$added_model" "$added_arguments" >> "$SWAPAI_PROFILES"
    else
        printf '%s\t%s\t%s\n' \
            "$added_name" "$added_backend" "$added_model" >> "$SWAPAI_PROFILES"
    fi
    swapai_info "Added profile: $added_name"
}

swapai_parse_profile_line() {
    profile_line=$1
    old_ifs=$IFS
    IFS="$(printf '\t')"
    # Profile fields intentionally split only on literal tab characters.
    # shellcheck disable=SC2086
    set -- $profile_line
    IFS=$old_ifs
    parsed_name=$1
    parsed_backend=$2
    parsed_model=$3
    parsed_arguments=${4:-}
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
    active_backend=$(swapai_active_value backend 2>/dev/null || true)
    if [ "$active_backend" = ollama-attach ]; then
        command -v curl >/dev/null 2>&1 || return 1
        curl -fsS --max-time 1 "$(swapai_api_endpoint)/models" >/dev/null 2>&1
        return $?
    fi
    running_pid=$(swapai_read_pid) || return 1
    kill -0 "$running_pid" 2>/dev/null
}

swapai_write_active() {
    active_name=$1
    active_backend=$2
    active_model=$3
    active_pid=$4
    active_ownership=$5
    {
        printf 'name=%s\n' "$active_name"
        printf 'backend=%s\n' "$active_backend"
        printf 'model=%s\n' "$active_model"
        printf 'host=%s\n' "${SWAPAI_RUNTIME_HOST:-$SWAPAI_HOST}"
        printf 'port=%s\n' "${SWAPAI_RUNTIME_PORT:-$SWAPAI_PORT}"
        printf 'pid=%s\n' "$active_pid"
        printf 'ownership=%s\n' "$active_ownership"
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
    SWAPAI_STARTED_PID=$started_pid
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
            OLLAMA_HOST="${SWAPAI_RUNTIME_HOST:-$SWAPAI_HOST}:${SWAPAI_RUNTIME_PORT:-$SWAPAI_PORT}" \
                swapai_start_process ollama serve
            ;;
        ollama-attach)
            SWAPAI_STARTED_PID=external
            ;;
        llamacpp)
            llama_bin=${SWAPAI_LLAMA_SERVER:-llama-server}
            command -v "$llama_bin" >/dev/null 2>&1 || {
                swapai_die "llama.cpp server not found: $llama_bin"
                return 1
            }
            swapai_start_process "$llama_bin" -m "$model" \
                --host "${SWAPAI_RUNTIME_HOST:-$SWAPAI_HOST}" \
                --port "${SWAPAI_RUNTIME_PORT:-$SWAPAI_PORT}" $extra_args
            ;;
        vllm)
            python_bin=${SWAPAI_PYTHON:-python3}
            command -v "$python_bin" >/dev/null 2>&1 || {
                swapai_die "python3 is not installed"
                return 1
            }
            swapai_start_process "$python_bin" -m vllm.entrypoints.openai.api_server \
                --model "$model" --host "${SWAPAI_RUNTIME_HOST:-$SWAPAI_HOST}" \
                --port "${SWAPAI_RUNTIME_PORT:-$SWAPAI_PORT}" $extra_args
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
    command -v curl >/dev/null 2>&1 || {
        swapai_error "curl is required for runtime health checks"
        return 1
    }
    attempt=0
    while [ "$attempt" -lt "$SWAPAI_START_TIMEOUT" ]; do
        swapai_is_running || return 1
        curl -fsS --max-time 1 \
            "$(swapai_api_endpoint)/models" >/dev/null 2>&1 && return 0
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

swapai_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

swapai_prepare_model() {
    prepared_backend=$1
    prepared_model=$2
    case $prepared_backend in
        ollama|ollama-attach) ;;
        *) return 0 ;;
    esac

    escaped_prepared_model=$(swapai_json_escape "$prepared_model")
    show_data="{\"model\":\"$escaped_prepared_model\"}"
    if ! curl -fsS --max-time 10 \
        -H 'Content-Type: application/json' \
        -d "$show_data" \
        "$(swapai_runtime_endpoint)/api/show" >/dev/null 2>&1; then
        swapai_error "Ollama model is not installed: $prepared_model"
        swapai_error "install it with: ollama pull $prepared_model"
        return 1
    fi

    swapai_info "Loading $prepared_model..."
    load_data="{\"model\":\"$escaped_prepared_model\",\"prompt\":\"\",\"stream\":false,\"keep_alive\":-1}"
    if ! curl -fsS --max-time "$SWAPAI_MODEL_TIMEOUT" \
        -H 'Content-Type: application/json' \
        -d "$load_data" \
        "$(swapai_runtime_endpoint)/api/generate" >/dev/null; then
        swapai_error "Ollama could not load model: $prepared_model"
        return 1
    fi
}

swapai_validate_profile_line() {
    validation_profile=$1
    swapai_parse_profile_line "$validation_profile"
    case $parsed_backend in
        ollama)
            command -v ollama >/dev/null 2>&1 || {
                swapai_die "ollama is not installed"
                return 1
            }
            command -v curl >/dev/null 2>&1 || {
                swapai_die "curl is required for Ollama readiness checks"
                return 1
            }
            ;;
        ollama-attach)
            command -v curl >/dev/null 2>&1 || {
                swapai_die "curl is required for Ollama attach mode"
                return 1
            }
            ;;
        llamacpp)
            validation_llama=${SWAPAI_LLAMA_SERVER:-llama-server}
            command -v "$validation_llama" >/dev/null 2>&1 || {
                swapai_die "llama.cpp server not found: $validation_llama"
                return 1
            }
            [ -r "$parsed_model" ] || {
                swapai_die "GGUF model is not readable: $parsed_model"
                return 1
            }
            ;;
        vllm)
            validation_python=${SWAPAI_PYTHON:-python3}
            command -v "$validation_python" >/dev/null 2>&1 || {
                swapai_die "python3 is not installed"
                return 1
            }
            "$validation_python" -c 'import vllm' >/dev/null 2>&1 || {
                swapai_die "vLLM is not installed for $validation_python"
                return 1
            }
            ;;
        mock) ;;
        *)
            swapai_die "unsupported backend '$parsed_backend'"
            return 1
            ;;
    esac
}

swapai_port_in_use() {
    checked_port=$1
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$checked_port" -sTCP:LISTEN -t >/dev/null 2>&1
        return $?
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v port=":$checked_port" '
            NR > 1 && $4 ~ port "$" { found = 1 }
            END { exit !found }
        '
        return $?
    fi
    return 1
}

swapai_activate_profile_line() {
    activation_profile=$1
    swapai_parse_profile_line "$activation_profile"

    SWAPAI_RUNTIME_HOST=$SWAPAI_HOST
    SWAPAI_RUNTIME_PORT=$SWAPAI_PORT
    activation_ownership=managed
    if [ "$parsed_backend" = ollama-attach ]; then
        SWAPAI_RUNTIME_PORT=$SWAPAI_OLLAMA_PORT
        activation_ownership=external
    fi

    if [ "$activation_ownership" = managed ] && swapai_port_in_use "$SWAPAI_RUNTIME_PORT"; then
        swapai_die "port $SWAPAI_PORT is already in use"
        return 1
    fi

    if [ "$activation_ownership" = external ]; then
        swapai_info "Attaching $parsed_name to Ollama on $SWAPAI_RUNTIME_HOST:$SWAPAI_RUNTIME_PORT..."
    else
        swapai_info "Starting $parsed_name ($parsed_backend: $parsed_model)..."
    fi
    swapai_start_backend \
        "$parsed_backend" "$parsed_model" "$parsed_arguments" || return 1
    activation_pid=$SWAPAI_STARTED_PID
    swapai_write_active \
        "$parsed_name" "$parsed_backend" "$parsed_model" "$activation_pid" "$activation_ownership"

    if ! swapai_wait_ready "$parsed_backend"; then
        swapai_error "runtime did not become ready; see 'swapai logs'"
        swapai_stop quiet >/dev/null 2>&1 || true
        return 1
    fi
    if ! swapai_prepare_model "$parsed_backend" "$parsed_model"; then
        swapai_stop quiet >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

swapai_switch() {
    case $# in
        1)
            requested=$1
            profile=$(swapai_profile "$requested") || {
                swapai_die "unknown profile '$requested'"
                return 1
            }
            ;;
        2)
            [ "$1" = --for-model ] || {
                swapai_die "usage: swapai switch <profile> | swapai switch --for-model <model>"
                return 1
            }
            requested_model=$2
            profile=$(swapai_profile_for_model "$requested_model") || {
                swapai_die "no profile maps model '$requested_model'"
                return 1
            }
            swapai_parse_profile_line "$profile"
            requested=$parsed_name
            swapai_info "Model $requested_model maps to profile $requested."
            ;;
        *)
            swapai_die "usage: swapai switch <profile> | swapai switch --for-model <model>"
            return 1
            ;;
    esac
    swapai_validate_profile_line "$profile" || return 1

    swapai_ensure_dirs || return 1
    previous_profile=
    if swapai_is_running; then
        current=$(swapai_active_value name 2>/dev/null || printf '')
        if [ -n "$current" ]; then
            previous_profile=$(swapai_profile "$current" 2>/dev/null || true)
        fi
        [ -n "$current" ] || current="current runtime"
        swapai_info "Stopping $current..."
        swapai_stop quiet || return 1
    fi

    if ! swapai_activate_profile_line "$profile"; then
        if [ -n "$previous_profile" ]; then
            swapai_info "Restoring previous runtime..."
            if swapai_activate_profile_line "$previous_profile"; then
                restored_name=$(swapai_active_value name)
                swapai_error "switch failed; restored $restored_name"
            else
                swapai_error "switch and rollback both failed"
            fi
        fi
        return 1
    fi

    swapai_parse_profile_line "$profile"
    swapai_info "Active: $parsed_name"
    swapai_info "API: $(swapai_api_endpoint)"
}

swapai_stop() {
    stop_mode=${1:-normal}
    stop_backend=$(swapai_active_value backend 2>/dev/null || true)
    if [ "$stop_backend" = ollama-attach ]; then
        rm -f "$SWAPAI_ACTIVE_FILE" "$SWAPAI_PID_FILE"
        [ "$stop_mode" = quiet ] || swapai_info "Detached from external Ollama runtime."
        return 0
    fi
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
    status_ownership=$(swapai_active_value ownership 2>/dev/null || printf 'managed')
    swapai_info "Ownership: $status_ownership"
    if [ "$status_ownership" = external ]; then
        swapai_info "PID: external"
    else
        swapai_info "PID: $(swapai_read_pid)"
    fi
    swapai_info "API: $(swapai_api_endpoint)"
}

swapai_runtime_endpoint() {
    runtime_host=${SWAPAI_RUNTIME_HOST:-}
    runtime_port=${SWAPAI_RUNTIME_PORT:-}
    if [ -z "$runtime_host" ]; then
        runtime_host=$(swapai_active_value host 2>/dev/null || printf '%s' "$SWAPAI_HOST")
    fi
    if [ -z "$runtime_port" ]; then
        runtime_port=$(swapai_active_value port 2>/dev/null || printf '%s' "$SWAPAI_PORT")
    fi
    printf 'http://%s:%s\n' "$runtime_host" "$runtime_port"
}

swapai_api_endpoint() {
    printf '%s/v1\n' "$(swapai_runtime_endpoint)"
}

swapai_endpoint() {
    swapai_api_endpoint
}

swapai_model() {
    swapai_is_running || {
        swapai_die "no runtime is active"
        return 1
    }
    swapai_active_value model
}

swapai_chat() {
    swapai_is_running || {
        swapai_die "no runtime is active"
        return 1
    }
    chat_backend=$(swapai_active_value backend)
    [ "$chat_backend" != mock ] || {
        swapai_die "the mock backend does not serve inference requests"
        return 1
    }
    command -v curl >/dev/null 2>&1 || {
        swapai_die "curl is required for chat requests"
        return 1
    }
    chat_model=$(swapai_active_value model)
    chat_prompt=${*:-Reply with exactly: ready}
    escaped_chat_model=$(swapai_json_escape "$chat_model")
    escaped_chat_prompt=$(swapai_json_escape "$chat_prompt")
    chat_data="{\"model\":\"$escaped_chat_model\",\"messages\":[{\"role\":\"user\",\"content\":\"$escaped_chat_prompt\"}],\"stream\":false}"
    chat_response=$(curl -fsS --max-time "$SWAPAI_MODEL_TIMEOUT" \
        -H 'Content-Type: application/json' \
        -d "$chat_data" "$(swapai_api_endpoint)/chat/completions") || {
        swapai_die "chat request failed"
        return 1
    }
    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$chat_response" | \
            jq -r '.choices[0].message.content // .error.message // .'
    else
        printf '%s\n' "$chat_response"
    fi
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

swapai_json_integer() {
    json_key=$1
    json_file=$2
    tr -d '\n\r' < "$json_file" | sed -n \
        "s/.*\"${json_key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"
}

swapai_time_difference() {
    time_total=$1
    time_start=$2
    awk -v total="$time_total" -v start="$time_start" 'BEGIN {
        difference = total - start
        if (difference < 0) difference = 0
        printf "%.3f", difference
    }'
}

swapai_tokens_per_second() {
    token_count=$1
    elapsed=$2
    awk -v tokens="$token_count" -v seconds="$elapsed" 'BEGIN {
        if (seconds <= 0) exit 1
        printf "%.1f", tokens / seconds
    }'
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
    escaped_prompt=$(swapai_json_escape "$bench_prompt")
    escaped_model=$(swapai_json_escape "$bench_model")
    bench_url="$(swapai_api_endpoint)/chat/completions"
    bench_data="{\"model\":\"$escaped_model\",\"messages\":[{\"role\":\"user\",\"content\":\"$escaped_prompt\"}],\"stream\":false}"
    nonstream_result=$(curl -fsS -o "$SWAPAI_STATE_HOME/benchmark.json" \
        -w '%{time_starttransfer} %{time_total}' -H 'Content-Type: application/json' \
        -d "$bench_data" "$bench_url") || {
        swapai_die "benchmark request failed"
        return 1
    }
    nonstream_total=$(printf '%s\n' "$nonstream_result" | awk '{ print $2 }')

    stream_data="{\"model\":\"$escaped_model\",\"messages\":[{\"role\":\"user\",\"content\":\"$escaped_prompt\"}],\"stream\":true,\"stream_options\":{\"include_usage\":true}}"
    stream_result=$(curl -fsS -N -o "$SWAPAI_STATE_HOME/benchmark.stream" \
        -w '%{time_starttransfer} %{time_total}' -H 'Content-Type: application/json' \
        -d "$stream_data" "$bench_url") || {
        swapai_die "streaming benchmark request failed"
        return 1
    }
    time_to_first_token=$(printf '%s\n' "$stream_result" | awk '{ print $1 }')
    stream_total=$(printf '%s\n' "$stream_result" | awk '{ print $2 }')
    generation_time=$(swapai_time_difference "$stream_total" "$time_to_first_token")
    completion_tokens=$(swapai_json_integer completion_tokens "$SWAPAI_STATE_HOME/benchmark.stream")
    if [ -z "$completion_tokens" ]; then
        completion_tokens=$(swapai_json_integer completion_tokens "$SWAPAI_STATE_HOME/benchmark.json")
    fi

    swapai_info "Model: $bench_model"
    swapai_info "Backend: $bench_backend"
    swapai_info "Non-streaming total: ${nonstream_total}s"
    swapai_info "Streaming total: ${stream_total}s"
    swapai_info "Time to first token: ${time_to_first_token}s"
    swapai_info "Generation time: ${generation_time}s"
    if [ -n "$completion_tokens" ]; then
        throughput=$(swapai_tokens_per_second "$completion_tokens" "$generation_time") || throughput=unavailable
        swapai_info "Completion tokens: $completion_tokens"
        swapai_info "Throughput: $throughput tokens/s"
    else
        swapai_info "Completion tokens: unavailable"
        swapai_info "Throughput: unavailable"
    fi
    swapai_info "Response: $SWAPAI_STATE_HOME/benchmark.json"
    swapai_info "Stream: $SWAPAI_STATE_HOME/benchmark.stream"
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

swapai_doctor_profiles() {
    if [ ! -f "$SWAPAI_PROFILES" ]; then
        printf '  [missing] %-12s %s\n' "Profiles" "$SWAPAI_PROFILES"
        return 1
    fi

    awk -F '\t' '
        /^[[:space:]]*($|#)/ { next }
        NF < 3 {
            count = split($0, fields, /[[:space:]]+/)
            if (count >= 3) {
                printf "  [invalid] Profiles     line %d uses spaces; use literal tabs between name, backend, and model\n", NR
            } else {
                printf "  [invalid] Profiles     line %d must contain at least name, backend, and model\n", NR
            }
            invalid = 1
            next
        }
        $1 == "" || $2 == "" || $3 == "" {
            printf "  [invalid] Profiles     line %d contains an empty required field\n", NR
            invalid = 1
        }
        END { exit invalid }
    ' "$SWAPAI_PROFILES"
    profile_status=$?
    if [ "$profile_status" -eq 0 ]; then
        printf '  [ok]      %-12s %s\n' "Profiles" "$SWAPAI_PROFILES"
    fi
    return "$profile_status"
}

swapai_doctor() {
    swapai_info "SwapAI $SWAPAI_VERSION"
    swapai_info "Configuration: $SWAPAI_PROFILES"
    swapai_info "State: $SWAPAI_STATE_HOME"
    swapai_info "API: $(swapai_api_endpoint)"
    swapai_info "Profiles:"
    doctor_status=0
    swapai_doctor_profiles || doctor_status=1
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
    return "$doctor_status"
}

swapai_main() {
    command_name=${1:-help}
    [ "$#" -eq 0 ] || shift
    case $command_name in
        init) swapai_init "$@" ;;
        add) swapai_add "$@" ;;
        list|ls) swapai_list "$@" ;;
        switch|use) swapai_switch "$@" ;;
        status) swapai_status "$@" ;;
        stop) swapai_stop "$@" ;;
        endpoint) swapai_endpoint "$@" ;;
        model) swapai_model "$@" ;;
        chat) swapai_chat "$@" ;;
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
