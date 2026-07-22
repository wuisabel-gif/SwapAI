#!/bin/sh

set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/swapai-test.XXXXXX")
SWAPAI_TEST_SHELL=${SWAPAI_TEST_SHELL:-sh}

swapai_cli() {
    "$SWAPAI_TEST_SHELL" "$TEST_ROOT/bin/swapai" "$@"
}

trap 'SWAPAI_CONFIG_HOME="$TEST_TMP/config" SWAPAI_STATE_HOME="$TEST_TMP/state" swapai_cli stop >/dev/null 2>&1 || true; rm -rf "$TEST_TMP"' EXIT HUP INT TERM

export SWAPAI_CONFIG_HOME="$TEST_TMP/config"
export SWAPAI_STATE_HOME="$TEST_TMP/state"
export SWAPAI_PROFILES="$SWAPAI_CONFIG_HOME/profiles.tsv"
export SWAPAI_ACTIVE_FILE="$SWAPAI_STATE_HOME/active"
export SWAPAI_PID_FILE="$SWAPAI_STATE_HOME/runtime.pid"
export SWAPAI_LOG_FILE="$SWAPAI_STATE_HOME/runtime.log"
export SWAPAI_START_TIMEOUT=3

assert_contains() {
    actual=$1
    expected=$2
    case $actual in
        *"$expected"*) ;;
        *) printf 'Expected output to contain: %s\nActual: %s\n' "$expected" "$actual" >&2; exit 1 ;;
    esac
}

swapai_cli init >/dev/null
add_output=$(swapai_cli add added ollama added-model)
assert_contains "$add_output" "Added profile: added"
if swapai_cli add added ollama duplicate >/dev/null 2>&1; then
    printf 'Expected duplicate profile creation to fail\n' >&2
    exit 1
fi
{
    printf 'test\tmock\tfixture\n'
    printf 'testb\tmock\tfixture-b\n'
    printf 'broken\tunsupported\tfixture\n'
    printf 'fakeollama\tollama\tfixture-model\n'
    printf 'attached\tollama-attach\tfixture-model\n'
    printf 'fakellama\tllamacpp\t%s\t--ctx-size 1024\n' "$TEST_ROOT/README.md"
    printf 'fakevllm\tvllm\tfixture/model\t--dtype auto\n'
    printf 'failllama\tllamacpp\t%s\n' "$TEST_ROOT/README.md"
} >> "$SWAPAI_PROFILES"

list_output=$(swapai_cli list)
assert_contains "$list_output" "coder"
assert_contains "$list_output" "added"
assert_contains "$list_output" "test"

switch_output=$(swapai_cli switch test)
assert_contains "$switch_output" "Active: test"

model_switch_output=$(swapai_cli switch --for-model fixture)
assert_contains "$model_switch_output" "Model fixture maps to profile test."
assert_contains "$model_switch_output" "Active: test"

status_output=$(swapai_cli status)
assert_contains "$status_output" "Status: running"
assert_contains "$status_output" "Backend: mock"
assert_contains "$status_output" "Model: fixture"

run_output=$(swapai_cli run testb -- true)
assert_contains "$run_output" "Restoring test..."
run_restored_status=$(swapai_cli status)
assert_contains "$run_restored_status" "Profile: test"
if swapai_cli run testb -- false >/dev/null 2>&1; then
    printf 'Expected a failing session command to preserve its exit status\n' >&2
    exit 1
fi
run_failed_status=$(swapai_cli status)
assert_contains "$run_failed_status" "Profile: test"

if swapai_cli switch broken >/dev/null 2>&1; then
    printf 'Expected broken runtime startup to fail\n' >&2
    exit 1
fi
rollback_status=$(swapai_cli status)
assert_contains "$rollback_status" "Profile: test"
assert_contains "$rollback_status" "Status: running"

FIXTURE_BIN="$TEST_ROOT/tests/fixtures/bin"
export SWAPAI_TEST_CAPTURE="$TEST_TMP/adapter-calls.log"
export PATH="$FIXTURE_BIN:$PATH"

swapai_cli switch fakeollama >/dev/null
ollama_capture=$(sed -n '1,20p' "$SWAPAI_TEST_CAPTURE")
assert_contains "$ollama_capture" "ollama|127.0.0.1:11435|serve"
assert_contains "$ollama_capture" "/v1/models"
assert_contains "$ollama_capture" "/api/show"
assert_contains "$ollama_capture" "/api/generate"

swapai_cli switch attached >/dev/null
attached_status=$(swapai_cli status)
assert_contains "$attached_status" "Backend: ollama-attach"
assert_contains "$attached_status" "Ownership: external"
assert_contains "$attached_status" "PID: external"
assert_contains "$attached_status" "API: http://127.0.0.1:11434/v1"
[ "$(grep -c '^ollama|' "$SWAPAI_TEST_CAPTURE")" -eq 1 ]

swapai_cli switch fakellama >/dev/null
llama_capture=$(sed -n '1,40p' "$SWAPAI_TEST_CAPTURE")
assert_contains "$llama_capture" "llamacpp|-m $TEST_ROOT/README.md"
assert_contains "$llama_capture" "--ctx-size 1024"

swapai_cli switch fakevllm >/dev/null
vllm_capture=$(sed -n '1,60p' "$SWAPAI_TEST_CAPTURE")
assert_contains "$vllm_capture" "vllm|-m vllm.entrypoints.openai.api_server"
assert_contains "$vllm_capture" "--model fixture/model"

model_output=$(swapai_cli model)
[ "$model_output" = "fixture/model" ]

chat_output=$(swapai_cli chat "hello from SwapAI")
assert_contains "$chat_output" "fixture response"

benchmark_output=$(swapai_cli benchmark "benchmark request")
assert_contains "$benchmark_output" "Non-streaming total: 0.012s"
assert_contains "$benchmark_output" "Streaming total: 0.020s"
assert_contains "$benchmark_output" "Time to first token: 0.004s"
assert_contains "$benchmark_output" "Generation time: 0.016s"
assert_contains "$benchmark_output" "Completion tokens: 4"
assert_contains "$benchmark_output" "Throughput: 250.0 tokens/s"
api_capture=$(sed -n '1,100p' "$SWAPAI_TEST_CAPTURE")
assert_contains "$api_capture" "/v1/chat/completions"
assert_contains "$api_capture" '"stream":true'

if SWAPAI_LLAMA_SERVER="$FIXTURE_BIN/fail-runtime" \
    swapai_cli switch failllama >/dev/null 2>&1; then
    printf 'Expected failing adapter startup to fail\n' >&2
    exit 1
fi
restored_status=$(swapai_cli status)
assert_contains "$restored_status" "Profile: fakevllm"

endpoint_output=$(swapai_cli endpoint)
[ "$endpoint_output" = "http://127.0.0.1:11435/v1" ]

swapai_cli stop >/dev/null
if swapai_cli status >/dev/null 2>&1; then
    printf 'Expected stopped status to return non-zero\n' >&2
    exit 1
fi

swapai_cli run testb -- true >/dev/null
if swapai_cli status >/dev/null 2>&1; then
    printf 'Expected session without a previous runtime to stop afterward\n' >&2
    exit 1
fi

if swapai_cli switch missing >/dev/null 2>&1; then
    printf 'Expected unknown profile to fail\n' >&2
    exit 1
fi

BAD_PROFILES="$TEST_TMP/bad-profiles.tsv"
printf 'spaces ollama broken-model\n' > "$BAD_PROFILES"
if doctor_output=$(SWAPAI_PROFILES="$BAD_PROFILES" swapai_cli doctor 2>&1); then
    printf 'Expected malformed profiles to fail doctor\n' >&2
    exit 1
fi
assert_contains "$doctor_output" "line 1 uses spaces"

SWAPAI_INSTALL_DIR="$TEST_TMP/bin" \
SWAPAI_SHARE_DIR="$TEST_TMP/share/swapai" \
    "$TEST_ROOT/install.sh" >/dev/null
installed_version=$("$TEST_TMP/bin/swapai" version)
assert_contains "$installed_version" "swapai 0.2.0"

printf 'All SwapAI tests passed.\n'
