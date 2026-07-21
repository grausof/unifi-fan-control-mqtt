#!/bin/bash
###############################################################################
# mqtt-control.sh: publishes Home Assistant MQTT Discovery messages at
# startup and persists incoming mode/pwm commands to MQTT_MODE_FILE, which
# fan-control.sh reads every loop iteration. Uses the pure-Bash MQTT client
# (mqtt-lib.sh) against a real local test broker - never mosquitto_pub/_sub.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: discovery payloads published for all entities ──────────────
scenario=$((scenario + 1))
setup_sandbox
start_test_broker

cat > "$SANDBOX/config" <<-CFG
MQTT_ENABLED=true
MQTT_HOST="127.0.0.1"
MQTT_PORT=${MQTT_TEST_PORT}
MQTT_USER=""
MQTT_PASSWORD=""
MQTT_BASE_TOPIC="unifi-fan-control"
MQTT_DISCOVERY_PREFIX="homeassistant"
CFG

start_mqtt_daemon
assert_eq "$(kill -0 "$MQTT_DAEMON_PID" 2>/dev/null && echo alive || echo dead)" "alive" "mqtt-control.sh should be running"

# Give mqtt-control.sh time to publish discovery (retained) before we
# subscribe, so our subscription triggers a *retained* redelivery (which is
# the only case MQTT brokers set the RETAIN flag on delivery).
/bin/sleep 1
start_mqtt_capture "homeassistant/#"

wait_for_mqtt_capture "_manual_pwm/config" 10 || fail "Expected all discovery messages to be captured"

log_content=$(cat "$SANDBOX/mqtt_capture.log")
assert_contains "$log_content" "homeassistant/sensor/" "should publish a sensor discovery config"
assert_contains "$log_content" "_state/config" "should publish the state sensor discovery config"
assert_contains "$log_content" "_temperature/config" "should publish the temperature sensor discovery config"
assert_contains "$log_content" "_pwm/config" "should publish the pwm sensor discovery config"
assert_contains "$log_content" "homeassistant/switch/" "should publish the auto-mode switch discovery config"
assert_contains "$log_content" "_auto_mode/config" "should publish the auto-mode switch discovery config"
assert_contains "$log_content" "homeassistant/number/" "should publish the manual pwm number discovery config"
assert_contains "$log_content" "_manual_pwm/config" "should publish the manual pwm number discovery config"
assert_contains "$log_content" "|1" "discovery messages should be retained (retain flag = 1)"

echo "  ✓ Scenario ${scenario}: Home Assistant discovery payloads published for sensors/switch/number"

stop_mqtt_capture
stop_mqtt_daemon
stop_test_broker
cleanup_sandbox

# ── Scenario 2: incoming commands are persisted to MQTT_MODE_FILE ──────────
scenario=$((scenario + 1))
setup_sandbox
start_test_broker

cat > "$SANDBOX/config" <<-CFG
MQTT_ENABLED=true
MQTT_HOST="127.0.0.1"
MQTT_PORT=${MQTT_TEST_PORT}
MQTT_BASE_TOPIC="unifi-fan-control"
MQTT_DISCOVERY_PREFIX="homeassistant"
CFG

device_id=$(hostname 2>/dev/null | tr -c 'a-zA-Z0-9_-' '-')
[[ -z "$device_id" ]] && device_id="unifi-fan-control"

start_mqtt_daemon

# Give mqtt-control.sh a moment to connect and subscribe before we publish
# the commands it's listening for.
/bin/sleep 1

mqtt_test_publish "unifi-fan-control/${device_id}/mode/set" "manual" ""
mqtt_test_publish "unifi-fan-control/${device_id}/pwm/set" "55" ""

wait_for_file_value "$SANDBOX/mqtt_mode" "MODE=manual
MANUAL_PWM_PERCENT=55" 10 || fail "Expected MQTT_MODE_FILE to be updated from incoming commands"

echo "  ✓ Scenario ${scenario}: incoming mode/pwm commands persisted to mqtt_mode file"

stop_mqtt_daemon
stop_test_broker
cleanup_sandbox

echo "  All ${scenario} MQTT discovery/command scenarios passed."
