#!/bin/bash
###############################################################################
# Standalone unit test for mqtt-lib.sh (the pure-Bash MQTT 3.1.1 client),
# exercised directly against a real local test broker. This test does NOT
# depend on fan-control.sh or mqtt-control.sh: it only sources mqtt-lib.sh
# and drives its public functions (mqtt_lib_connect/publish/subscribe_multi/
# read_packet/disconnect) to confirm the wire protocol implementation is
# correct on its own, independent of any daemon integration built on top.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

setup_sandbox
start_test_broker

# ── Scenario 1: connect, publish (non-retained) and receive round-trip ──────
scenario=$((scenario + 1))
start_mqtt_capture "unifi-fan-control/lib-test/+"

mqtt_test_publish "unifi-fan-control/lib-test/hello" '{"msg":"hi"}'

wait_for_mqtt_capture 'unifi-fan-control/lib-test/hello' 10 ||
    fail "Expected the published message to be captured by a subscriber"

captured="$(tail -n 1 "$SANDBOX/mqtt_capture.log")"
assert_contains "$captured" "unifi-fan-control/lib-test/hello" "captured line should contain the published topic"
assert_contains "$captured" '{"msg":"hi"}' "captured line should contain the published payload"
assert_contains "$captured" "|0" "a non-retained publish should be reported with retain=0"

echo "  ✓ Scenario ${scenario}: connect/publish/subscribe round-trip works"

stop_mqtt_capture

# ── Scenario 2: retain flag is correctly propagated ─────────────────────────
scenario=$((scenario + 1))
mqtt_test_publish "unifi-fan-control/lib-test/retained" '{"v":1}' retain

start_mqtt_capture "unifi-fan-control/lib-test/retained"
wait_for_mqtt_capture "unifi-fan-control/lib-test/retained" 10 ||
    fail "Expected the retained message to be delivered to a new subscriber"

captured="$(tail -n 1 "$SANDBOX/mqtt_capture.log")"
assert_contains "$captured" '{"v":1}' "retained payload should be delivered on (re)subscribe"
assert_contains "$captured" "|1" "a retained publish should be reported with retain=1"

echo "  ✓ Scenario ${scenario}: retain flag survives a fresh subscribe"

stop_mqtt_capture

# ── Scenario 3: mqtt_lib_subscribe_multi accepts several topic filters ──────
scenario=$((scenario + 1))
start_mqtt_capture "unifi-fan-control/lib-test/a" # single-topic capture helper; verify multi manually below

(
    source "$REPO_ROOT/mqtt-lib.sh"
    if mqtt_lib_connect "127.0.0.1" "$MQTT_TEST_PORT" "test-multi-$$" "" "" 30; then
        mqtt_lib_subscribe_multi "unifi-fan-control/lib-test/a" "unifi-fan-control/lib-test/b"
        deadline=$((SECONDS + 5))
        got_a=false
        got_b=false
        while ((SECONDS < deadline)) && { [[ "$got_a" == false ]] || [[ "$got_b" == false ]]; }; do
            mqtt_lib_read_packet 5
            if [[ "$MQTT_LIB_LAST_PACKET_TYPE" == "PUBLISH" ]]; then
                [[ "$MQTT_LIB_RX_TOPIC" == "unifi-fan-control/lib-test/a" ]] && got_a=true
                [[ "$MQTT_LIB_RX_TOPIC" == "unifi-fan-control/lib-test/b" ]] && got_b=true
            fi
        done
        mqtt_lib_disconnect
        [[ "$got_a" == true && "$got_b" == true ]]
    fi
) &
multi_pid=$!
/bin/sleep 0.3

mqtt_test_publish "unifi-fan-control/lib-test/a" '{"n":"a"}'
mqtt_test_publish "unifi-fan-control/lib-test/b" '{"n":"b"}'

wait "$multi_pid" || fail "mqtt_lib_subscribe_multi should receive messages on all subscribed filters"

echo "  ✓ Scenario ${scenario}: mqtt_lib_subscribe_multi delivers messages for every filter"

stop_mqtt_capture
stop_test_broker
cleanup_sandbox

echo "  All ${scenario} mqtt-lib.sh unit scenarios passed."
