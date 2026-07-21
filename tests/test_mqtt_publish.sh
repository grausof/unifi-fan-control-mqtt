#!/bin/bash
###############################################################################
# When MQTT_ENABLED=true, fan-control.sh must publish a retained JSON state
# message to <base_topic>/<device>/state on every loop iteration, using the
# pure-Bash MQTT client (mqtt-lib.sh) against a real local test broker.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: state, temperature and pwm are published ───────────────────
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

start_mqtt_capture "unifi-fan-control/+/state"

echo "45" > "$SANDBOX/cputemp"
start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

/bin/sleep 1
echo "70" > "$SANDBOX/cputemp"

wait_for_log "OFF→ACTIVE" 15 || fail "Expected OFF→ACTIVE transition"

wait_for_mqtt_capture '"state":"ACTIVE"' 15 || fail "Expected a captured MQTT state publish with state=ACTIVE"

last_line=$(tail -n 1 "$SANDBOX/mqtt_capture.log")
assert_contains "$last_line" "unifi-fan-control/" "published topic should use the configured base topic"
assert_contains "$last_line" "/state|" "published topic should be the state topic"
assert_contains "$last_line" '"state":"ACTIVE"' "payload should include the current state name"
assert_contains "$last_line" '"mode":"auto"' "payload should include auto mode by default"
assert_contains "$last_line" '"temp_smooth":' "payload should include smoothed temperature"
assert_contains "$last_line" '"pwm":' "payload should include current pwm"

echo "  ✓ Scenario ${scenario}: MQTT state published with expected JSON fields"

stop_mqtt_capture
stop_daemon
stop_test_broker
cleanup_sandbox

echo "  All ${scenario} MQTT publish scenarios passed."
