#!/bin/bash
###############################################################################
# Manual mode (set via mqtt-control.sh / Home Assistant): fan-control.sh
# bypasses the state machine's ramp/deadband logic and applies the requested
# PWM percentage directly - EXCEPT for the MAX_TEMP safety backstop, which
# always applies even in manual mode and forces Auto Mode back on if the
# device reaches a critical temperature (e.g. a slider left at a low value
# by an HA automation and forgotten).
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: manual PWM applied and stays fixed at a safe temperature ───
scenario=$((scenario + 1))
setup_sandbox
start_test_broker

cat >"$SANDBOX/config" <<-CFG
MQTT_ENABLED=true
MQTT_HOST="127.0.0.1"
MQTT_PORT=${MQTT_TEST_PORT}
CFG

# 70°C is well below the default MAX_TEMP=85 - the backstop must not interfere.
echo "70" >"$SANDBOX/cputemp"

cat >"$SANDBOX/mqtt_mode" <<-MODE
MODE=manual
MANUAL_PWM_PERCENT=40
MODE

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

# (40 * 255 + 50) / 100 = 102, rounded
expected_pwm=102
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "$expected_pwm" 10 || fail "Manual PWM 40% should map to pwm=$expected_pwm"

/bin/sleep 1
pwm=$(get_pwm)
assert_eq "$pwm" "$expected_pwm" "PWM should remain fixed at the manual value at a safe temperature"

if grep -q "→EMERGENCY\|SET:.*EMERGENCY:" "$SANDBOX/syslog" 2>/dev/null; then
    fail "No EMERGENCY failsafe override is expected while in manual mode below MAX_TEMP"
fi
grep -q "MANUAL:" "$SANDBOX/syslog" || fail "Expected a MANUAL: log entry"

echo "  ✓ Scenario ${scenario}: manual PWM applied, no override at a safe temperature"

stop_daemon
stop_test_broker
cleanup_sandbox

# ── Scenario 2: MAX_TEMP backstop forces Auto Mode back on ─────────────────
scenario=$((scenario + 1))
setup_sandbox
start_test_broker

cat >"$SANDBOX/config" <<-CFG
MQTT_ENABLED=true
MQTT_HOST="127.0.0.1"
MQTT_PORT=${MQTT_TEST_PORT}
CFG

# 95°C is above the default MAX_TEMP=85 - the backstop must kick in even
# though a low manual PWM (10%) is requested.
echo "95" >"$SANDBOX/cputemp"

cat >"$SANDBOX/mqtt_mode" <<-MODE
MODE=manual
MANUAL_PWM_PERCENT=10
MODE

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 10 || fail "MAX_TEMP backstop should force PWM to MAX_PWM"
wait_for_log "ALERT: MANUAL PWM backstop triggered" 10 || fail "Expected an ALERT: MANUAL PWM backstop triggered log entry"

# The backstop must persist MODE=auto back to the mode file so mqtt-control.sh
# / Home Assistant's Auto Mode switch reflects the forced state.
/bin/sleep 1
grep -q "^MODE=auto" "$SANDBOX/mqtt_mode" || fail "mqtt_mode file should be rewritten with MODE=auto after the backstop trips"

echo "  ✓ Scenario ${scenario}: MAX_TEMP backstop forces Auto Mode and MAX_PWM"

stop_daemon
stop_test_broker
cleanup_sandbox

# ── Scenario 3: switching back to auto mode resumes the state machine ──────
scenario=$((scenario + 1))
setup_sandbox
start_test_broker

cat >"$SANDBOX/config" <<-CFG
MQTT_ENABLED=true
MQTT_HOST="127.0.0.1"
MQTT_PORT=${MQTT_TEST_PORT}
CFG

echo "45" >"$SANDBOX/cputemp"
cat >"$SANDBOX/mqtt_mode" <<-MODE
MODE=manual
MANUAL_PWM_PERCENT=100
MODE

start_daemon
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 10 || fail "Manual PWM 100% should map to pwm=255"

# Switch back to auto: below activation threshold, fan should go to 0 (OFF state)
cat >"$SANDBOX/mqtt_mode" <<-MODE
MODE=auto
MANUAL_PWM_PERCENT=100
MODE

wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "0" 10 || fail "Switching back to auto with cold temp should turn the fan off"

echo "  ✓ Scenario ${scenario}: switching mqtt_mode back to auto resumes automatic control"

stop_daemon
stop_test_broker
cleanup_sandbox

echo "  All ${scenario} manual-mode scenarios passed."
