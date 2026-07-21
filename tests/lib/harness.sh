#!/bin/bash
###############################################################################
# Test harness for fan-control.sh — sandboxed, no root, no device needed.
# Source this file from every test script.
#
# Usage:
#   source "$(dirname "$0")/lib/harness.sh"
#   setup_sandbox
#   trap teardown_sandbox EXIT
#   start_daemon
#   ... assertions ...
#   # For multi-scenario tests, call cleanup_sandbox between scenarios
#   # (cleanup_sandbox removes the daemon + tmp dir and returns;
#   #  teardown_sandbox is the EXIT-trap handler that exits with the saved code).
###############################################################################

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAN_CONTROL_SCRIPT="${FAN_CONTROL_SCRIPT:-$REPO_ROOT/fan-control.sh}"
TEST_DIR="$REPO_ROOT/tests"

# ── Sandbox ──────────────────────────────────────────────────────────────────
# All state lives here.  Created by setup_sandbox, destroyed by teardown_sandbox.
SANDBOX=""
DAEMON_PID=""

setup_sandbox() {
    SANDBOX=$(mktemp -d /tmp/fanctl-test.XXXXXX)
    export SANDBOX

    # Override all device paths to point into the sandbox
    export FAN_CONTROL_CONFIG_FILE="$SANDBOX/config"
    export FAN_CONTROL_TEMP_STATE_FILE="$SANDBOX/temp_state"
    export FAN_CONTROL_PID_FILE="$SANDBOX/pid"
    export FAN_CONTROL_OPTIMAL_PWM_FILE="$SANDBOX/optimal_pwm"
    export FAN_CONTROL_HWMON_BASE="$SANDBOX/hwmon"
    # MQTT is optional and off by default; these paths are only read/written
    # when MQTT_ENABLED=true in the config file, but are always sandboxed so
    # MQTT tests never touch the real filesystem.
    export FAN_CONTROL_MQTT_MODE_FILE="$SANDBOX/mqtt_mode"
    export FAN_CONTROL_MQTT_PID_FILE="$SANDBOX/mqtt-control.pid"

    # Build fake hwmon tree — one device with one PWM channel
    local hwmon_dir="$SANDBOX/hwmon/hwmon0"
    mkdir -p "$hwmon_dir"
    echo 0 > "$hwmon_dir/pwm1"
    echo 3000 > "$hwmon_dir/fan1_input"   # RPM — fan spinning by default
    echo "fake-driver" > "$hwmon_dir/name"

    # Create stub bin directory PREPENDED to PATH
    mkdir -p "$SANDBOX/bin"
    export PATH="$SANDBOX/bin:$PATH"

    # Stub: ubnt-systool — reads $SANDBOX/cputemp; exits 1 on missing or FAIL
    cat > "$SANDBOX/bin/ubnt-systool" <<'STUB'
#!/bin/bash
if [[ "$1" != "cputemp" ]]; then
    echo "unknown arg: $*" >&2
    exit 1
fi
cputemp_file="${SANDBOX:-/tmp}/cputemp"
if [[ ! -f "$cputemp_file" ]]; then
    exit 1
fi
val=$(cat "$cputemp_file" 2>/dev/null || true)
if [[ -z "$val" || "$val" == "FAIL" ]]; then
    exit 1
fi
echo "$val"
STUB
    chmod +x "$SANDBOX/bin/ubnt-systool"

    # Stub: logger — appends arguments to $SANDBOX/syslog
    cat > "$SANDBOX/bin/logger" <<'STUB'
#!/bin/bash
echo "$@" >> "${SANDBOX:-/tmp}/syslog"
STUB
    chmod +x "$SANDBOX/bin/logger"

    # Stub: sleep — accelerates daemon loop by sleeping 0.05s
    cat > "$SANDBOX/bin/sleep" <<'STUB'
#!/bin/bash
exec /bin/sleep 0.05
STUB
    chmod +x "$SANDBOX/bin/sleep"

    # Create the cputemp control file (tests write temperatures here)
    echo "50" > "$SANDBOX/cputemp"

    # Clean syslog
    : > "$SANDBOX/syslog"
}

# Kill daemon + remove sandbox tmp dir.  Returns (does not exit) so multi-scenario
# test files can call it between scenarios without terminating the test.
cleanup_sandbox() {
    if [[ -n "${DAEMON_PID:-}" ]]; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    DAEMON_PID=""
    if [[ -n "${MQTT_DAEMON_PID:-}" ]]; then
        kill "$MQTT_DAEMON_PID" 2>/dev/null || true
        wait "$MQTT_DAEMON_PID" 2>/dev/null || true
    fi
    MQTT_DAEMON_PID=""
    if [[ -n "${MQTT_CAPTURE_PID:-}" ]]; then
        kill "$MQTT_CAPTURE_PID" 2>/dev/null || true
        wait "$MQTT_CAPTURE_PID" 2>/dev/null || true
    fi
    MQTT_CAPTURE_PID=""
    if [[ -n "${MQTT_BROKER_PID:-}" ]]; then
        kill "$MQTT_BROKER_PID" 2>/dev/null || true
        wait "$MQTT_BROKER_PID" 2>/dev/null || true
    fi
    MQTT_BROKER_PID=""
    if [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]]; then
        rm -rf "$SANDBOX"
    fi
    SANDBOX=""
}

# EXIT-trap handler: clean up and exit with the saved exit code.
teardown_sandbox() {
    local ret=$?
    cleanup_sandbox
    exit $ret
}

# ── Daemon lifecycle ─────────────────────────────────────────────────────────
start_daemon() {
    # shellcheck disable=SC2086
    bash "$FAN_CONTROL_SCRIPT" &
    DAEMON_PID=$!
    # Give the daemon a moment to bootstrap and enter the main loop
    /bin/sleep 0.5
}

stop_daemon() {
    if [[ -n "${DAEMON_PID:-}" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    DAEMON_PID=""
}

# ── Wait helpers ─────────────────────────────────────────────────────────────
# Poll syslog until a grep pattern matches or timeout expires
wait_for_log() {
    local pattern="$1"
    local timeout_s="${2:-10}"
    local elapsed=0
    while (( elapsed < timeout_s * 10 )); do
        if grep -q "$pattern" "$SANDBOX/syslog" 2>/dev/null; then
            return 0
        fi
        /bin/sleep 0.1
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT: wait_for_log '${pattern}' after ${timeout_s}s" >&2
    echo "--- syslog contents ---" >&2
    cat "$SANDBOX/syslog" >&2
    return 1
}

# Poll a file until its content equals the expected value or timeout expires
wait_for_file_value() {
    local file="$1"
    local expected="$2"
    local timeout_s="${3:-15}"
    local elapsed=0
    while (( elapsed < timeout_s * 10 )); do
        local val
        val=$(cat "$file" 2>/dev/null || echo "")
        if [[ "$val" == "$expected" ]]; then
            return 0
        fi
        /bin/sleep 0.1
        elapsed=$((elapsed + 1))
    done
    local actual
    actual=$(cat "$file" 2>/dev/null || echo "<unreadable>")
    echo "TIMEOUT: wait_for_file_value '${file}' expected='${expected}' got='${actual}' after ${timeout_s}s" >&2
    return 1
}

# Poll a file until its value is greater than expected, or timeout
wait_for_file_gt() {
    local file="$1"
    local expected="$2"
    local timeout_s="${3:-15}"
    local elapsed=0
    while (( elapsed < timeout_s * 10 )); do
        local val
        val=$(cat "$file" 2>/dev/null || echo "0")
        if (( val > expected )); then
            return 0
        fi
        /bin/sleep 0.1
        elapsed=$((elapsed + 1))
    done
    local actual
    actual=$(cat "$file" 2>/dev/null || echo "<unreadable>")
    echo "TIMEOUT: wait_for_file_gt '${file}' expected >${expected} got='${actual}' after ${timeout_s}s" >&2
    return 1
}

# ── Assertions ───────────────────────────────────────────────────────────────
assert_eq() {
    local got="$1"
    local expected="$2"
    local msg="${3:-}"
    if [[ "$got" != "$expected" ]]; then
        echo "FAIL: ${msg}expected '${expected}', got '${got}'" >&2
        exit 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if ! grep -q "$needle" <<<"$haystack"; then
        echo "FAIL: ${msg}expected to contain '${needle}'" >&2
        echo "--- haystack ---" >&2
        echo "$haystack" >&2
        exit 1
    fi
}

fail() {
    local msg="$1"
    echo "FAIL: $msg" >&2
    exit 1
}

# ── Helpers ──────────────────────────────────────────────────────────────────
# Get the current PWM value from pwm1
get_pwm() {
    cat "$SANDBOX/hwmon/hwmon0/pwm1" 2>/dev/null || echo "0"
}

# Check if the daemon process is still alive
daemon_alive() {
    if [[ -n "${DAEMON_PID:-}" ]]; then
        kill -0 "$DAEMON_PID" 2>/dev/null
    else
        return 1
    fi
}

# Check if PID file exists and contains the daemon's PID
pid_file_valid() {
    local pid_file="${FAN_CONTROL_PID_FILE:-$SANDBOX/pid}"
    [[ -f "$pid_file" ]] && [[ "$(cat "$pid_file" 2>/dev/null)" == "${DAEMON_PID:-}" ]]
}

# ── MQTT test helpers (optional feature) ────────────────────────────────────
# These tests exercise the real pure-Bash MQTT client (mqtt-lib.sh) against a
# real local mosquitto *broker* instance. The broker binary is only a test
# dependency (installed via `brew install mosquitto` for local development);
# the shipped project itself never invokes mosquitto_pub/mosquitto_sub or any
# other external MQTT client - see mqtt-lib.sh.
MQTT_BROKER_PID=""
MQTT_TEST_PORT=""

# Start a throwaway local mosquitto broker (anonymous access, random high
# port) for the duration of one test scenario.
start_test_broker() {
    MQTT_TEST_PORT=$(( 20000 + RANDOM % 10000 ))
    cat > "$SANDBOX/mosquitto.conf" <<-CONF
	listener ${MQTT_TEST_PORT} 127.0.0.1
	allow_anonymous true
	CONF
    mosquitto -c "$SANDBOX/mosquitto.conf" > "$SANDBOX/mosquitto.log" 2>&1 &
    MQTT_BROKER_PID=$!

    local waited=0
    while ! grep -q "mosquitto version .* running" "$SANDBOX/mosquitto.log" 2>/dev/null; do
        (( waited >= 50 )) && fail "Test mosquitto broker did not start within 5s"
        /bin/sleep 0.1
        waited=$((waited + 1))
    done
}

stop_test_broker() {
    if [[ -n "${MQTT_BROKER_PID:-}" ]]; then
        kill "$MQTT_BROKER_PID" 2>/dev/null || true
        wait "$MQTT_BROKER_PID" 2>/dev/null || true
    fi
    MQTT_BROKER_PID=""
}

# Subscribe in the background using our own mqtt-lib.sh (never mosquitto_sub)
# and append every received message as "topic|payload|retain" lines to
# $SANDBOX/mqtt_capture.log, for test assertions.
MQTT_CAPTURE_PID=""

start_mqtt_capture() {
    local topic_filter="$1"
    : > "$SANDBOX/mqtt_capture.log"
    (
        source "$REPO_ROOT/mqtt-lib.sh"
        if mqtt_lib_connect "127.0.0.1" "$MQTT_TEST_PORT" "test-capture-$$" "" "" 30; then
            mqtt_lib_subscribe_multi "$topic_filter"
            while true; do
                mqtt_lib_read_packet 5
                case "$MQTT_LIB_LAST_PACKET_TYPE" in
                    PUBLISH)
                        echo "${MQTT_LIB_RX_TOPIC}|${MQTT_LIB_RX_PAYLOAD}|${MQTT_LIB_RX_RETAIN}" >> "$SANDBOX/mqtt_capture.log"
                        ;;
                    DISCONNECTED)
                        break
                        ;;
                esac
            done
        fi
    ) &
    MQTT_CAPTURE_PID=$!
    /bin/sleep 0.3
}

stop_mqtt_capture() {
    if [[ -n "${MQTT_CAPTURE_PID:-}" ]]; then
        kill "$MQTT_CAPTURE_PID" 2>/dev/null || true
        wait "$MQTT_CAPTURE_PID" 2>/dev/null || true
    fi
    MQTT_CAPTURE_PID=""
}

# Publish a single message using our own mqtt-lib.sh (never mosquitto_pub),
# for tests that need to simulate an incoming command from Home Assistant.
mqtt_test_publish() {
    local topic="$1" payload="$2" retain="${3:-}"
    (
        source "$REPO_ROOT/mqtt-lib.sh"
        if mqtt_lib_connect "127.0.0.1" "$MQTT_TEST_PORT" "test-pub-$$" "" "" 30; then
            mqtt_lib_publish "$topic" "$payload" "$retain"
            mqtt_lib_disconnect
        fi
    )
}

# Poll $SANDBOX/mqtt_capture.log until a line matching the given grep pattern
# appears, or timeout expires.
wait_for_mqtt_capture() {
    local pattern="$1"
    local timeout_s="${2:-10}"
    local elapsed=0
    while (( elapsed < timeout_s * 10 )); do
        if grep -q "$pattern" "$SANDBOX/mqtt_capture.log" 2>/dev/null; then
            return 0
        fi
        /bin/sleep 0.1
        elapsed=$((elapsed + 1))
    done
    echo "TIMEOUT: wait_for_mqtt_capture '${pattern}' after ${timeout_s}s" >&2
    echo "--- mqtt_capture.log contents ---" >&2
    cat "$SANDBOX/mqtt_capture.log" 2>/dev/null >&2
    return 1
}

# ── mqtt-control.sh daemon lifecycle ────────────────────────────────────────
MQTT_CONTROL_SCRIPT="${MQTT_CONTROL_SCRIPT:-$REPO_ROOT/mqtt-control.sh}"

start_mqtt_daemon() {
    bash "$MQTT_CONTROL_SCRIPT" &
    MQTT_DAEMON_PID=$!
    /bin/sleep 0.5
}

stop_mqtt_daemon() {
    if [[ -n "${MQTT_DAEMON_PID:-}" ]] && kill -0 "$MQTT_DAEMON_PID" 2>/dev/null; then
        kill -TERM "$MQTT_DAEMON_PID" 2>/dev/null || true
        wait "$MQTT_DAEMON_PID" 2>/dev/null || true
    fi
    MQTT_DAEMON_PID=""
}
