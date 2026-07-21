#!/bin/bash
###############################################################################
# UniFi Fan Control - MQTT Command Listener (OPTIONAL companion service)
#
# This script is only useful when MQTT_ENABLED=true in the shared config file.
# It runs as a separate systemd service (mqtt-control.service) so the main
# fan-control.sh loop never depends on MQTT being configured or reachable.
#
# It uses the pure-Bash MQTT client in mqtt-lib.sh (no mosquitto-clients
# dependency - UniFi OS devices have no package manager to install it with).
#
# Responsibilities:
#   - Publish Home Assistant MQTT Discovery messages (retained) so entities
#     (sensors, an "Auto Mode" switch, and a "Manual PWM" number slider)
#     appear automatically in Home Assistant.
#   - Subscribe to command topics (mode/set, pwm/set) and persist the desired
#     mode/PWM to MQTT_MODE_FILE, which fan-control.sh reads every loop
#     iteration. Persisted to disk so manual mode survives a reboot.
###############################################################################

CONFIG_FILE="${FAN_CONTROL_CONFIG_FILE:-/data/fan-control/config}"
MQTT_MODE_FILE="${FAN_CONTROL_MQTT_MODE_FILE:-/data/fan-control/mqtt_mode}"
PID_FILE="${FAN_CONTROL_MQTT_PID_FILE:-/var/run/mqtt-control.pid}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MQTT_LIB_FILE="${FAN_CONTROL_MQTT_LIB_FILE:-$SCRIPT_DIR/mqtt-lib.sh}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t mqtt-control "FATAL: Config file not found: $CONFIG_FILE (start fan-control.service first)"
    exit 1
fi

if [[ ! -f "$MQTT_LIB_FILE" ]]; then
    logger -t mqtt-control "FATAL: mqtt-lib.sh not found at $MQTT_LIB_FILE"
    exit 1
fi
# shellcheck source=mqtt-lib.sh
source "$MQTT_LIB_FILE"

# Single instance lock, mirroring fan-control.sh's approach.
exec 200>>"$PID_FILE"
if ! flock -n 200; then
    logger -t mqtt-control "ALERT: Another instance already holds the lock (PID $(cat "$PID_FILE" 2>/dev/null))"
    exit 1
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE" 2>/dev/null' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Atomic write helper, mirroring fan-control.sh's atomic_write_file.
atomic_write_file() {
    local target_file="$1"
    local content="$2"
    local temp_file="${target_file}.tmp"

    if ! printf '%s\n' "$content" > "$temp_file" 2>/dev/null; then
        logger -t mqtt-control "ERROR: Failed to write to temporary file for $target_file"
        return 1
    elif ! mv "$temp_file" "$target_file" 2>/dev/null; then
        logger -t mqtt-control "ERROR: Failed to update file $target_file"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi
    return 0
}

MQTT_MODE="auto"
MQTT_MANUAL_PWM_PERCENT=0

load_mode_file() {
    [[ -f "$MQTT_MODE_FILE" ]] || return 0
    local file_mode="" file_pwm=""
    while IFS='=' read -r key value; do
        case "$key" in
            MODE) file_mode="$value" ;;
            MANUAL_PWM_PERCENT) file_pwm="$value" ;;
        esac
    done < "$MQTT_MODE_FILE" 2>/dev/null
    [[ "$file_mode" == "auto" || "$file_mode" == "manual" ]] && MQTT_MODE="$file_mode"
    if [[ "$file_pwm" =~ ^[0-9]+$ ]] && (( file_pwm >= 0 && file_pwm <= 100 )); then
        MQTT_MANUAL_PWM_PERCENT=$file_pwm
    fi
}

save_mode_file() {
    atomic_write_file "$MQTT_MODE_FILE" "MODE=${MQTT_MODE}
MANUAL_PWM_PERCENT=${MQTT_MANUAL_PWM_PERCENT}"
}

# Reload configuration (parameters may change while this service runs, e.g.
# after re-running install.sh with different broker settings).
reload_config() {
    source "$CONFIG_FILE" 2>/dev/null
    [[ "$MQTT_ENABLED" == "true" ]]
}

if ! reload_config; then
    logger -t mqtt-control "INFO: MQTT_ENABLED is not true - idling"
    # Idle instead of exiting so systemd doesn't restart-loop; re-checks periodically
    # in case the config is updated (e.g. user re-runs install.sh to enable MQTT).
    while ! reload_config; do
        sleep 60
    done
fi

load_mode_file
save_mode_file  # ensure the file exists with valid defaults from the very first run

MQTT_DEVICE_ID="$(hostname 2>/dev/null | tr -c 'a-zA-Z0-9_-' '-')"
[[ -z "$MQTT_DEVICE_ID" ]] && MQTT_DEVICE_ID="unifi-fan-control"
BASE_TOPIC="${MQTT_BASE_TOPIC}/${MQTT_DEVICE_ID}"
STATE_TOPIC="${BASE_TOPIC}/state"
MODE_SET_TOPIC="${BASE_TOPIC}/mode/set"
PWM_SET_TOPIC="${BASE_TOPIC}/pwm/set"
# Dedicated availability topic for the Manual PWM slider, published by this
# script (not fan-control.sh) so enabling/disabling the slider in Home
# Assistant is instant on mode change, instead of waiting up to
# CHECK_INTERVAL for fan-control.sh's next state_topic publish.
MANUAL_PWM_AVAIL_TOPIC="${BASE_TOPIC}/manual_pwm/availability"

# Publish "online"/"offline" to MANUAL_PWM_AVAIL_TOPIC based on the current
# in-memory MQTT_MODE. Called right after any mode change, and once after
# discovery, so the slider's enabled/disabled state is always immediate.
publish_manual_pwm_availability() {
    local payload="offline"
    [[ "$MQTT_MODE" == "manual" ]] && payload="online"
    mqtt_lib_publish "$MANUAL_PWM_AVAIL_TOPIC" "$payload" "retain"
}

# Publish Home Assistant MQTT Discovery messages (retained) for all entities,
# over the already-open MQTT connection. Uses value_template to read fields
# out of the JSON state message published by fan-control.sh on STATE_TOPIC,
# so mqtt-control.sh doesn't need to publish telemetry itself.
publish_discovery() {
    local device_json
    device_json=$(printf '{"identifiers":["%s"],"name":"UniFi Fan Control (%s)","manufacturer":"iceteaSA (community fork)","model":"unifi-fan-control-mqtt"}' \
        "$MQTT_DEVICE_ID" "$MQTT_DEVICE_ID")

    # Sensor: controller state (OFF/TAPER/ACTIVE/EMERGENCY/MANUAL)
    mqtt_lib_publish "${MQTT_DISCOVERY_PREFIX}/sensor/${MQTT_DEVICE_ID}_state/config" \
        "$(printf '{"name":"Fan Control State","unique_id":"%s_state","state_topic":"%s","value_template":"{{ value_json.state }}","icon":"mdi:state-machine","device":%s}' \
            "$MQTT_DEVICE_ID" "$STATE_TOPIC" "$device_json")" "retain"

    # Sensor: smoothed temperature
    mqtt_lib_publish "${MQTT_DISCOVERY_PREFIX}/sensor/${MQTT_DEVICE_ID}_temperature/config" \
        "$(printf '{"name":"Fan Control Temperature","unique_id":"%s_temperature","state_topic":"%s","value_template":"{{ value_json.temp_smooth }}","unit_of_measurement":"°C","device_class":"temperature","state_class":"measurement","icon":"mdi:thermometer","device":%s}' \
            "$MQTT_DEVICE_ID" "$STATE_TOPIC" "$device_json")" "retain"

    # Sensor: current fan speed as a percentage (0-100%), computed by
    # fan-control.sh from the raw 0-255 PWM value (pwm_percent field).
    # state_class "measurement" tells Home Assistant this is a numeric time
    # series, so it renders a line graph in History/Statistics instead of a
    # plain discrete-state list.
    mqtt_lib_publish "${MQTT_DISCOVERY_PREFIX}/sensor/${MQTT_DEVICE_ID}_pwm/config" \
        "$(printf '{"name":"Fan Speed","unique_id":"%s_pwm","state_topic":"%s","value_template":"{{ value_json.pwm_percent }}","unit_of_measurement":"%%","state_class":"measurement","icon":"mdi:fan","device":%s}' \
            "$MQTT_DEVICE_ID" "$STATE_TOPIC" "$device_json")" "retain"

    # Switch: Auto Mode (ON = automatic state machine, OFF = manual control).
    # "optimistic":true makes Home Assistant flip the UI immediately on
    # command, instead of waiting up to CHECK_INTERVAL (default 15s) for
    # fan-control.sh's next state_topic publish to confirm it.
    mqtt_lib_publish "${MQTT_DISCOVERY_PREFIX}/switch/${MQTT_DEVICE_ID}_auto_mode/config" \
        "$(printf '{"name":"Fan Control Auto Mode","unique_id":"%s_auto_mode","state_topic":"%s","value_template":"{{ value_json.mode }}","command_topic":"%s","payload_on":"auto","payload_off":"manual","state_on":"auto","state_off":"manual","optimistic":true,"icon":"mdi:autorenew","device":%s}' \
            "$MQTT_DEVICE_ID" "$STATE_TOPIC" "$MODE_SET_TOPIC" "$device_json")" "retain"

    # Number: Manual PWM percentage slider (0-100%), only meaningful when Auto
    # Mode is off. availability_topic points to MANUAL_PWM_AVAIL_TOPIC, which
    # this script (not fan-control.sh) publishes instantly on every mode
    # change, so the slider greys out/enables immediately - no reliance on
    # fan-control.sh's slower CHECK_INTERVAL telemetry cycle.
    mqtt_lib_publish "${MQTT_DISCOVERY_PREFIX}/number/${MQTT_DEVICE_ID}_manual_pwm/config" \
        "$(printf '{"name":"Fan Control Manual PWM","unique_id":"%s_manual_pwm","state_topic":"%s","value_template":"{{ value_json.pwm_percent }}","command_topic":"%s","min":0,"max":100,"step":1,"unit_of_measurement":"%%","optimistic":true,"availability_topic":"%s","payload_available":"online","payload_not_available":"offline","icon":"mdi:speedometer","device":%s}' \
            "$MQTT_DEVICE_ID" "$STATE_TOPIC" "$PWM_SET_TOPIC" "$MANUAL_PWM_AVAIL_TOPIC" "$device_json")" "retain"

    # Publish the initial availability right after discovery so Home
    # Assistant reflects the slider's correct enabled/disabled state from the
    # very first connection, without waiting for a mode change.
    publish_manual_pwm_availability

    logger -t mqtt-control "DISCOVERY: Published Home Assistant discovery messages for device ${MQTT_DEVICE_ID}"
}

# Handle a single incoming command (mode/set or pwm/set) already stored in
# MQTT_LIB_RX_TOPIC / MQTT_LIB_RX_PAYLOAD by mqtt_lib_read_packet.
handle_command() {
    local topic="$MQTT_LIB_RX_TOPIC" payload="$MQTT_LIB_RX_PAYLOAD"
    case "$topic" in
        "$MODE_SET_TOPIC")
            if [[ "$payload" == "auto" || "$payload" == "manual" ]]; then
                MQTT_MODE="$payload"
                save_mode_file
                # Publish availability immediately so the Manual PWM slider's
                # enabled/disabled state updates in Home Assistant right away,
                # instead of waiting for fan-control.sh's next state publish.
                publish_manual_pwm_availability
                logger -t mqtt-control "COMMAND: Mode set to ${MQTT_MODE}"
            else
                logger -t mqtt-control "WARNING: Ignoring invalid mode payload: $payload"
            fi
            ;;
        "$PWM_SET_TOPIC")
            if [[ "$payload" =~ ^[0-9]+$ ]] && (( payload >= 0 && payload <= 100 )); then
                MQTT_MANUAL_PWM_PERCENT=$payload
                save_mode_file
                logger -t mqtt-control "COMMAND: Manual PWM set to ${payload}%"
            else
                logger -t mqtt-control "WARNING: Ignoring invalid pwm payload: $payload"
            fi
            ;;
    esac
}

logger -t mqtt-control "START: Listening for commands on ${MODE_SET_TOPIC} and ${PWM_SET_TOPIC}"

# Keepalive interval (seconds) advertised to the broker in CONNECT; PINGREQ is
# sent well before this elapses with no traffic, to keep the connection alive.
MQTT_KEEPALIVE=30

# Main loop: maintain one persistent MQTT connection, sending PINGREQ as
# needed, and reconnecting with a short backoff on any disconnect.
while true; do
    if ! reload_config; then
        logger -t mqtt-control "INFO: MQTT disabled at runtime - idling"
        while ! reload_config; do sleep 60; done
    fi

    # Re-sync in-memory mode/pwm from disk in case it changed on disk since
    # our last connection attempt (e.g. install.sh re-ran, or manual edit).
    load_mode_file

    if ! mqtt_lib_connect "$MQTT_HOST" "$MQTT_PORT" "${MQTT_DEVICE_ID}-ctrl" "$MQTT_USER" "$MQTT_PASSWORD" "$MQTT_KEEPALIVE"; then
        logger -t mqtt-control "ALERT: MQTT connect failed ($MQTT_LIB_LAST_ERROR) - retrying in 5s"
        sleep 5
        continue
    fi

    mqtt_lib_subscribe_multi "$MODE_SET_TOPIC" "$PWM_SET_TOPIC"
    publish_discovery

    last_ping=$(date +%s)
    connection_alive=true
    while [[ "$connection_alive" == true ]]; do
        # Wait up to just under half the keepalive interval so PINGREQ is
        # always sent well before the broker's own keepalive timeout.
        mqtt_lib_read_packet $(( MQTT_KEEPALIVE / 2 ))

        case "$MQTT_LIB_LAST_PACKET_TYPE" in
            PUBLISH)
                handle_command
                ;;
            DISCONNECTED)
                connection_alive=false
                ;;
            TIMEOUT|PINGRESP|OTHER)
                now=$(date +%s)
                if (( now - last_ping >= MQTT_KEEPALIVE / 2 )); then
                    if ! mqtt_lib_ping; then
                        connection_alive=false
                    fi
                    last_ping=$now
                fi
                ;;
        esac
    done

    logger -t mqtt-control "ALERT: MQTT connection lost - reconnecting in 5s"
    mqtt_lib_disconnect
    sleep 5
done
