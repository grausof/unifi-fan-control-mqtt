#!/bin/bash
###############################################################################
# Manual mode (set via mqtt-control.sh / Home Assistant): fan-control.sh must
# bypass the state machine entirely and apply the requested PWM percentage
# with NO EMERGENCY failsafe override, even at critical temperatures. This is
# an explicit, documented user choice.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: manual PWM applied and stays fixed despite critical temp ────
scenario=$((scenario + 1))
setup_sandbox
start_test_broker

cat > "$SANDBOX/config" <<-CFG
MQTT_ENABLED=true
MQTT_HOST="127.0.0.1"
MQTT_PORT=${MQTT_TEST_PORT}
CFG

# 95°C is above the default MAX_TEMP=85 (EMERGENCY territory in auto mode)
echo "95" > "$SANDBOX/cputemp"

cat > "$SANDBOX/mqtt_mode" <<-MODE
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
assert_eq "$pwm" "$expected_pwm" "PWM should remain fixed at the manual value despite critical temperature"

if grep -q "→EMERGENCY\|SET:.*EMERGENCY:" "$SANDBOX/syslog" 2>/dev/null; then
    fail "No EMERGENCY failsafe override is expected while in manual mode"
fi
grep -q "MANUAL:" "$SANDBOX/syslog" || fail "Expected a MANUAL: log entry"

echo "  ✓ Scenario ${scenario}: manual PWM applied, no EMERGENCY override at critical temp"

stop_daemon
stop_test_broker
cleanup_sandbox

# ── Scenario 2: switching back to auto mode resumes the state machine ──────
scenario=$((scenario + 1))
setup_sandbox
start_test_broker

cat > "$SANDBOX/config" <<-CFG
MQTT_ENABLED=true
MQTT_HOST="127.0.0.1"
MQTT_PORT=${MQTT_TEST_PORT}
CFG

echo "45" > "$SANDBOX/cputemp"
cat > "$SANDBOX/mqtt_mode" <<-MODE
MODE=manual
MANUAL_PWM_PERCENT=100
MODE

start_daemon
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 10 || fail "Manual PWM 100% should map to pwm=255"

# Switch back to auto: below activation threshold, fan should go to 0 (OFF state)
cat > "$SANDBOX/mqtt_mode" <<-MODE
MODE=auto
MANUAL_PWM_PERCENT=100
MODE

wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "0" 10 || fail "Switching back to auto with cold temp should turn the fan off"

echo "  ✓ Scenario ${scenario}: switching mqtt_mode back to auto resumes automatic control"

stop_daemon
stop_test_broker
cleanup_sandbox

echo "  All ${scenario} manual-mode scenarios passed."
