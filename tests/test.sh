#!/bin/sh

set -eu

TEST_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/swapai-test.XXXXXX")
trap 'SWAPAI_CONFIG_HOME="$TEST_TMP/config" SWAPAI_STATE_HOME="$TEST_TMP/state" "$TEST_ROOT/bin/swapai" stop >/dev/null 2>&1 || true; rm -rf "$TEST_TMP"' EXIT HUP INT TERM

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

"$TEST_ROOT/bin/swapai" init >/dev/null
printf 'test\tmock\tfixture\n' >> "$SWAPAI_PROFILES"
printf 'broken\tunsupported\tfixture\n' >> "$SWAPAI_PROFILES"
printf 'fakeollama\tollama\tfixture-model\n' >> "$SWAPAI_PROFILES"
printf 'fakellama\tllamacpp\t%s\t--ctx-size 1024\n' "$TEST_ROOT/README.md" >> "$SWAPAI_PROFILES"
printf 'fakevllm\tvllm\tfixture/model\t--dtype auto\n' >> "$SWAPAI_PROFILES"
printf 'failllama\tllamacpp\t%s\n' "$TEST_ROOT/README.md" >> "$SWAPAI_PROFILES"

list_output=$("$TEST_ROOT/bin/swapai" list)
assert_contains "$list_output" "coder"
assert_contains "$list_output" "test"

switch_output=$("$TEST_ROOT/bin/swapai" switch test)
assert_contains "$switch_output" "Active: test"

status_output=$("$TEST_ROOT/bin/swapai" status)
assert_contains "$status_output" "Status: running"
assert_contains "$status_output" "Backend: mock"
assert_contains "$status_output" "Model: fixture"

if "$TEST_ROOT/bin/swapai" switch broken >/dev/null 2>&1; then
    printf 'Expected broken runtime startup to fail\n' >&2
    exit 1
fi
rollback_status=$("$TEST_ROOT/bin/swapai" status)
assert_contains "$rollback_status" "Profile: test"
assert_contains "$rollback_status" "Status: running"

FIXTURE_BIN="$TEST_ROOT/tests/fixtures/bin"
export SWAPAI_TEST_CAPTURE="$TEST_TMP/adapter-calls.log"
export PATH="$FIXTURE_BIN:$PATH"

"$TEST_ROOT/bin/swapai" switch fakeollama >/dev/null
ollama_capture=$(sed -n '1,20p' "$SWAPAI_TEST_CAPTURE")
assert_contains "$ollama_capture" "ollama|127.0.0.1:11435|serve"
assert_contains "$ollama_capture" "/api/show"
assert_contains "$ollama_capture" "/api/generate"

"$TEST_ROOT/bin/swapai" switch fakellama >/dev/null
llama_capture=$(sed -n '1,40p' "$SWAPAI_TEST_CAPTURE")
assert_contains "$llama_capture" "llamacpp|-m $TEST_ROOT/README.md"
assert_contains "$llama_capture" "--ctx-size 1024"

"$TEST_ROOT/bin/swapai" switch fakevllm >/dev/null
vllm_capture=$(sed -n '1,60p' "$SWAPAI_TEST_CAPTURE")
assert_contains "$vllm_capture" "vllm|-m vllm.entrypoints.openai.api_server"
assert_contains "$vllm_capture" "--model fixture/model"

if SWAPAI_LLAMA_SERVER="$FIXTURE_BIN/fail-runtime" \
    "$TEST_ROOT/bin/swapai" switch failllama >/dev/null 2>&1; then
    printf 'Expected failing adapter startup to fail\n' >&2
    exit 1
fi
restored_status=$("$TEST_ROOT/bin/swapai" status)
assert_contains "$restored_status" "Profile: fakevllm"

endpoint_output=$("$TEST_ROOT/bin/swapai" endpoint)
[ "$endpoint_output" = "http://127.0.0.1:11435" ]

"$TEST_ROOT/bin/swapai" stop >/dev/null
if "$TEST_ROOT/bin/swapai" status >/dev/null 2>&1; then
    printf 'Expected stopped status to return non-zero\n' >&2
    exit 1
fi

if "$TEST_ROOT/bin/swapai" switch missing >/dev/null 2>&1; then
    printf 'Expected unknown profile to fail\n' >&2
    exit 1
fi

SWAPAI_INSTALL_DIR="$TEST_TMP/bin" \
SWAPAI_SHARE_DIR="$TEST_TMP/share/swapai" \
    "$TEST_ROOT/install.sh" >/dev/null
installed_version=$("$TEST_TMP/bin/swapai" version)
assert_contains "$installed_version" "swapai 0.1.0"

printf 'All SwapAI tests passed.\n'
