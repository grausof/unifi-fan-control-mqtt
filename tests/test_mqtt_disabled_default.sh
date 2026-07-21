#!/bin/bash
###############################################################################
# MQTT is disabled by default: fan-control.sh must behave exactly like
# upstream, with zero MQTT connection attempts and no mqtt_mode file writes.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: default config (MQTT_ENABLED not set yet) ───────────────────
scenario=$((scenario + 1))
setup_sandbox

echo "45" > "$SANDBOX/cputemp"
start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

/bin/sleep 1
echo "70" > "$SANDBOX/cputemp"

wait_for_log "OFF→ACTIVE" 15 || fail "Normal state machine should still work with MQTT disabled"

if grep -q "MQTT: " "$SANDBOX/syslog" 2>/dev/null; then
    fail "No MQTT-related log entries should appear when MQTT_ENABLED=false: $(cat "$SANDBOX/syslog")"
fi

grep -q "^MQTT_ENABLED=false" "$SANDBOX/config" || fail "MQTT_ENABLED should default to false in the bootstrapped config"

echo "  ✓ Scenario ${scenario}: MQTT disabled by default, no MQTT activity, unchanged behavior"

stop_daemon
cleanup_sandbox

# ── Scenario 2: explicit MQTT_ENABLED=false ─────────────────────────────────
scenario=$((scenario + 1))
setup_sandbox

cat > "$SANDBOX/config" <<-CFG
MQTT_ENABLED=false
CFG

echo "45" > "$SANDBOX/cputemp"
start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

/bin/sleep 1
pwm=$(get_pwm)
assert_eq "$pwm" "0" "PWM should be 0 when below activation temp, got $pwm"

if grep -q "MQTT: " "$SANDBOX/syslog" 2>/dev/null; then
    fail "No MQTT activity expected with explicit MQTT_ENABLED=false"
fi

echo "  ✓ Scenario ${scenario}: explicit MQTT_ENABLED=false also skips MQTT entirely"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} MQTT-disabled scenarios passed."
