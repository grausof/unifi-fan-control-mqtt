#!/bin/bash
###############################################################################
# UniFi Intelligent Fan Controller
###############################################################################

###[ CONFIGURATION ]###########################################################
CONFIG_FILE="${FAN_CONTROL_CONFIG_FILE:-/data/fan-control/config}"
TEMP_STATE_FILE="${FAN_CONTROL_TEMP_STATE_FILE:-/data/fan-control/temp_state}"
HWMON_BASE="${FAN_CONTROL_HWMON_BASE:-/sys/class/hwmon}"
# Shared file written by mqtt-control.sh (mode/manual PWM), read every loop iteration.
# Only consulted when MQTT_ENABLED=true; otherwise fan-control.sh behaves exactly like upstream.
MQTT_MODE_FILE="${FAN_CONTROL_MQTT_MODE_FILE:-/data/fan-control/mqtt_mode}"

# Pure-Bash MQTT client library (no mosquitto-clients dependency; see mqtt-lib.sh).
# Only sourced/used when MQTT_ENABLED=true. Resolved relative to this script's own
# location so it works regardless of the caller's current working directory.
FAN_CONTROL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MQTT_LIB_FILE="${FAN_CONTROL_MQTT_LIB_FILE:-$FAN_CONTROL_SCRIPT_DIR/mqtt-lib.sh}"

# Define default configuration values
DEFAULT_MIN_PWM=91             # Minimum active fan speed (0-255)
DEFAULT_MAX_PWM=255            # Maximum fan speed (0-255)
DEFAULT_MIN_TEMP=60            # Base threshold (°C)
DEFAULT_MAX_TEMP=85            # Critical temperature (°C)
DEFAULT_HYSTERESIS=5           # Temperature buffer (°C)
DEFAULT_CHECK_INTERVAL=15      # Base check interval (seconds)
DEFAULT_TAPER_MINS=90          # Cool-down duration (minutes)
DEFAULT_FAN_PWM_AUTODETECT=true       # Auto-detect all active fan PWM channels
DEFAULT_FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"  # Only used when FAN_PWM_AUTODETECT=false
DEFAULT_OPTIMAL_PWM_FILE="${FAN_CONTROL_OPTIMAL_PWM_FILE:-/data/fan-control/optimal_pwm}"
DEFAULT_MAX_PWM_STEP=25        # Max PWM change per adjustment
DEFAULT_DEADBAND=1             # Temp stability threshold (°C)
DEFAULT_ALPHA=20               # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100)
DEFAULT_LEARNING_RATE=5        # PWM optimization step size

# MQTT integration is OPTIONAL and disabled by default. When MQTT_ENABLED=false
# (default), none of the MQTT code paths run and the script behaves exactly like
# upstream fan-control.sh.
DEFAULT_MQTT_ENABLED=false           # Enable MQTT state publishing + manual mode support
DEFAULT_MQTT_HOST="127.0.0.1"        # MQTT broker host
DEFAULT_MQTT_PORT=1883               # MQTT broker port
DEFAULT_MQTT_USER=""                 # MQTT broker username (optional)
DEFAULT_MQTT_PASSWORD=""             # MQTT broker password (optional)
DEFAULT_MQTT_BASE_TOPIC="unifi-fan-control"  # Base topic namespace (combined with hostname)
DEFAULT_MQTT_DISCOVERY_PREFIX="homeassistant"  # Home Assistant MQTT discovery prefix

# Create config file if it doesn't exist
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t fan-control "CONFIG: Creating new config file"

    # Create directory if it doesn't exist
    config_dir=$(dirname "$CONFIG_FILE")
    if [[ ! -d "$config_dir" ]]; then
        if ! mkdir -p "$config_dir" 2>/dev/null; then
            logger -t fan-control "FATAL: Failed to create config directory: $config_dir"
            exit 1
        fi
    fi

    # Use a temporary file and atomic move to prevent partial writes
    temp_config="${CONFIG_FILE}.tmp"
    if ! cat > "$temp_config" <<-DEFAULTS 2>/dev/null; then
MIN_PWM=$DEFAULT_MIN_PWM             # Minimum active fan speed (0-255)
MAX_PWM=$DEFAULT_MAX_PWM            # Maximum fan speed (0-255)
MIN_TEMP=$DEFAULT_MIN_TEMP            # Base threshold (°C)
MAX_TEMP=$DEFAULT_MAX_TEMP            # Critical temperature (°C)
HYSTERESIS=$DEFAULT_HYSTERESIS           # Temperature buffer (°C)
CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL      # Base check interval (seconds)
TAPER_MINS=$DEFAULT_TAPER_MINS          # Cool-down duration (minutes)
FAN_PWM_AUTODETECT=$DEFAULT_FAN_PWM_AUTODETECT  # Auto-detect all active fan PWM channels
FAN_PWM_DEVICE="$DEFAULT_FAN_PWM_DEVICE"  # Only used when FAN_PWM_AUTODETECT=false
OPTIMAL_PWM_FILE="$DEFAULT_OPTIMAL_PWM_FILE"
MAX_PWM_STEP=$DEFAULT_MAX_PWM_STEP        # Max PWM change per adjustment
DEADBAND=$DEFAULT_DEADBAND             # Temp stability threshold (°C)
ALPHA=$DEFAULT_ALPHA               # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100)
LEARNING_RATE=$DEFAULT_LEARNING_RATE        # PWM optimization step size
MQTT_ENABLED=$DEFAULT_MQTT_ENABLED        # Enable MQTT state publishing + manual mode support (optional feature)
MQTT_HOST="$DEFAULT_MQTT_HOST"        # MQTT broker host
MQTT_PORT=$DEFAULT_MQTT_PORT        # MQTT broker port
MQTT_USER="$DEFAULT_MQTT_USER"        # MQTT broker username (optional)
MQTT_PASSWORD="$DEFAULT_MQTT_PASSWORD"        # MQTT broker password (optional)
MQTT_BASE_TOPIC="$DEFAULT_MQTT_BASE_TOPIC"        # Base topic namespace (combined with hostname)
MQTT_DISCOVERY_PREFIX="$DEFAULT_MQTT_DISCOVERY_PREFIX"        # Home Assistant MQTT discovery prefix
DEFAULTS
        logger -t fan-control "FATAL: Failed to write to temporary config file"
        exit 1
    elif ! mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
        logger -t fan-control "FATAL: Failed to create config file"
        rm -f "$temp_config" 2>/dev/null  # Clean up the temporary file
        exit 1
    else
        logger -t fan-control "CONFIG: New configuration file created successfully"
    fi
fi


# Source the config file
source "$CONFIG_FILE" 2>/dev/null

# Check if each required parameter is defined, and add missing ones
missing_params=()
missing_values=()
missing_comments=()

check_param() {
    local param=$1
    local default_value=$2
    local comment=$3

    if ! grep -q "^${param}=" "$CONFIG_FILE" 2>/dev/null; then
        logger -t fan-control "CONFIG: Missing parameter detected: $param"
        missing_params+=("$param")
        missing_values+=("$default_value")
        missing_comments+=("$comment")
        # Set the value in the current environment
        eval "${param}=${default_value}"
    fi
}

# Check each parameter
check_param "MIN_PWM" "$DEFAULT_MIN_PWM" "# Minimum active fan speed (0-255)"
check_param "MAX_PWM" "$DEFAULT_MAX_PWM" "# Maximum fan speed (0-255)"
check_param "MIN_TEMP" "$DEFAULT_MIN_TEMP" "# Base threshold (°C)"
check_param "MAX_TEMP" "$DEFAULT_MAX_TEMP" "# Critical temperature (°C)"
check_param "HYSTERESIS" "$DEFAULT_HYSTERESIS" "# Temperature buffer (°C)"
check_param "CHECK_INTERVAL" "$DEFAULT_CHECK_INTERVAL" "# Base check interval (seconds)"
check_param "TAPER_MINS" "$DEFAULT_TAPER_MINS" "# Cool-down duration (minutes)"
check_param "FAN_PWM_AUTODETECT" "$DEFAULT_FAN_PWM_AUTODETECT" "# Auto-detect all active fan PWM channels"
check_param "FAN_PWM_DEVICE" "\"$DEFAULT_FAN_PWM_DEVICE\"" "# Fan PWM device path (only used when FAN_PWM_AUTODETECT=false)"
check_param "OPTIMAL_PWM_FILE" "\"$DEFAULT_OPTIMAL_PWM_FILE\"" "# Optimal PWM file path"
check_param "MAX_PWM_STEP" "$DEFAULT_MAX_PWM_STEP" "# Max PWM change per adjustment"
check_param "DEADBAND" "$DEFAULT_DEADBAND" "# Temp stability threshold (°C)"
check_param "ALPHA" "$DEFAULT_ALPHA" "# Smoothing factor (0-100)"
check_param "LEARNING_RATE" "$DEFAULT_LEARNING_RATE" "# PWM optimization step size"
check_param "MQTT_ENABLED" "$DEFAULT_MQTT_ENABLED" "# Enable MQTT state publishing + manual mode support (optional feature)"
check_param "MQTT_HOST" "\"$DEFAULT_MQTT_HOST\"" "# MQTT broker host"
check_param "MQTT_PORT" "$DEFAULT_MQTT_PORT" "# MQTT broker port"
check_param "MQTT_USER" "\"$DEFAULT_MQTT_USER\"" "# MQTT broker username (optional)"
check_param "MQTT_PASSWORD" "\"$DEFAULT_MQTT_PASSWORD\"" "# MQTT broker password (optional)"
check_param "MQTT_BASE_TOPIC" "\"$DEFAULT_MQTT_BASE_TOPIC\"" "# Base topic namespace (combined with hostname)"
check_param "MQTT_DISCOVERY_PREFIX" "\"$DEFAULT_MQTT_DISCOVERY_PREFIX\"" "# Home Assistant MQTT discovery prefix"

# If missing parameters were found, update the config file atomically
if [ ${#missing_params[@]} -gt 0 ]; then
    logger -t fan-control "CONFIG: Updating configuration file with ${#missing_params[@]} missing parameters"

    # Create a temporary file
    temp_config="${CONFIG_FILE}.tmp"

    # Copy existing config to temp file
    if ! cp "$CONFIG_FILE" "$temp_config" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to create temporary config file for update"
        # Continue with current in-memory values, but don't update the file
    else
        # Add each missing parameter
        update_failed=false
        for i in "${!missing_params[@]}"; do
            if ! echo "${missing_params[$i]}=${missing_values[$i]}        ${missing_comments[$i]}" >> "$temp_config" 2>/dev/null; then
                logger -t fan-control "ERROR: Failed to add parameter ${missing_params[$i]} to config file"
                update_failed=true
                break
            fi
        done

        if [ "$update_failed" = true ]; then
            logger -t fan-control "ERROR: Config file update failed"
            rm -f "$temp_config" 2>/dev/null  # Clean up the temporary file
        else
            # Replace the original file with the updated one
            if ! mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
                logger -t fan-control "ERROR: Failed to update config file"
                rm -f "$temp_config" 2>/dev/null  # Clean up the temporary file
            else
                logger -t fan-control "CONFIG: Configuration file updated successfully"
            fi
        fi
    fi
fi

###[ CONFIG MIGRATION ]########################################################
# Migrate configs from older versions of fan-control
# This block runs once per upgrade and rewrites the config file with updated
# parameter names, comments, and structure. It is idempotent.
migrate_config() {
    local needs_migration=false
    local migration_reasons=()

    # Migration 1: FAN_PWM_DEVICE pointing to a raw sysfs device path
    # Older versions on UDM-SE required manually setting the raw path.
    # With auto-detection, this is no longer needed — reset to the standard default
    # so users aren't confused by a stale raw path when FAN_PWM_AUTODETECT=true.
    if [[ "$FAN_PWM_AUTODETECT" != "false" ]] && \
       [[ "$FAN_PWM_DEVICE" != "$DEFAULT_FAN_PWM_DEVICE" ]] && \
       [[ "$FAN_PWM_DEVICE" != "/sys/class/hwmon/hwmon0/pwm1" ]]; then
        migration_reasons+=("FAN_PWM_DEVICE reset to default (was: $FAN_PWM_DEVICE)")
        FAN_PWM_DEVICE="$DEFAULT_FAN_PWM_DEVICE"
        needs_migration=true
    fi

    [[ "$needs_migration" = false ]] && return 0

    for reason in "${migration_reasons[@]}"; do
        logger -t fan-control "MIGRATE: $reason"
    done

    # Rewrite config with migrated values atomically
    local temp_config="${CONFIG_FILE}.tmp"
    if cat > "$temp_config" <<-CONFIG 2>/dev/null; then
MIN_PWM=$MIN_PWM             # Minimum active fan speed (0-255)
MAX_PWM=$MAX_PWM            # Maximum fan speed (0-255)
MIN_TEMP=$MIN_TEMP            # Base threshold (°C)
MAX_TEMP=$MAX_TEMP            # Critical temperature (°C)
HYSTERESIS=$HYSTERESIS           # Temperature buffer (°C)
CHECK_INTERVAL=$CHECK_INTERVAL      # Base check interval (seconds)
TAPER_MINS=$TAPER_MINS          # Cool-down duration (minutes)
FAN_PWM_AUTODETECT=$FAN_PWM_AUTODETECT  # Auto-detect all active fan PWM channels
FAN_PWM_DEVICE="$FAN_PWM_DEVICE"  # Only used when FAN_PWM_AUTODETECT=false
OPTIMAL_PWM_FILE="$OPTIMAL_PWM_FILE"
MAX_PWM_STEP=$MAX_PWM_STEP        # Max PWM change per adjustment
DEADBAND=$DEADBAND             # Temp stability threshold (°C)
ALPHA=$ALPHA               # Smoothing factor (0-100)
LEARNING_RATE=$LEARNING_RATE        # PWM optimization step size
CONFIG
        if mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
            logger -t fan-control "MIGRATE: Config file updated successfully"
        else
            logger -t fan-control "MIGRATE: Failed to update config file"
            rm -f "$temp_config" 2>/dev/null
        fi
    else
        logger -t fan-control "MIGRATE: Failed to write temporary config file"
        rm -f "$temp_config" 2>/dev/null
    fi
}

migrate_config

# Validate configuration parameters
validate_config() {
    local param=$1
    local value=$2
    local min=$3
    local max=$4
    local default=$5

    if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < min || value > max )); then
        logger -t fan-control "CONFIG: Invalid $param value: $value (should be between $min and $max), using default: $default"
        eval "${param}=${default}"
        return 1
    fi
    return 0
}

# Validate numeric parameters
config_changed=false

validate_config "MIN_PWM" "$MIN_PWM" 0 255 "$DEFAULT_MIN_PWM" || config_changed=true
validate_config "MAX_PWM" "$MAX_PWM" "${MIN_PWM:-$DEFAULT_MIN_PWM}" 255 "$DEFAULT_MAX_PWM" || config_changed=true
validate_config "MIN_TEMP" "$MIN_TEMP" 30 80 "$DEFAULT_MIN_TEMP" || config_changed=true
validate_config "MAX_TEMP" "$MAX_TEMP" "$MIN_TEMP" 100 "$DEFAULT_MAX_TEMP" || config_changed=true
validate_config "HYSTERESIS" "$HYSTERESIS" 1 15 "$DEFAULT_HYSTERESIS" || config_changed=true
validate_config "CHECK_INTERVAL" "$CHECK_INTERVAL" 5 60 "$DEFAULT_CHECK_INTERVAL" || config_changed=true
validate_config "TAPER_MINS" "$TAPER_MINS" 1 240 "$DEFAULT_TAPER_MINS" || config_changed=true
validate_config "MAX_PWM_STEP" "$MAX_PWM_STEP" 1 50 "$DEFAULT_MAX_PWM_STEP" || config_changed=true
validate_config "DEADBAND" "$DEADBAND" 0 10 "$DEFAULT_DEADBAND" || config_changed=true
validate_config "ALPHA" "$ALPHA" 1 99 "$DEFAULT_ALPHA" || config_changed=true
validate_config "LEARNING_RATE" "$LEARNING_RATE" 1 20 "$DEFAULT_LEARNING_RATE" || config_changed=true

# MQTT_ENABLED is a boolean flag, not a numeric range - validate separately
if [[ "$MQTT_ENABLED" != "true" && "$MQTT_ENABLED" != "false" ]]; then
    logger -t fan-control "CONFIG: Invalid MQTT_ENABLED value: $MQTT_ENABLED, using default: $DEFAULT_MQTT_ENABLED"
    MQTT_ENABLED=$DEFAULT_MQTT_ENABLED
fi
validate_config "MQTT_PORT" "$MQTT_PORT" 1 65535 "$DEFAULT_MQTT_PORT" || true

# If any config values were corrected, update the config file
if [ "$config_changed" = true ]; then
    logger -t fan-control "CONFIG: Updating configuration file with corrected values"

    # Create a temporary file
    temp_config="${CONFIG_FILE}.tmp"

    # Write corrected values to temp file
    if ! cat > "$temp_config" <<-CONFIG 2>/dev/null; then
MIN_PWM=$MIN_PWM             # Minimum active fan speed (0-255)
MAX_PWM=$MAX_PWM            # Maximum fan speed (0-255)
MIN_TEMP=$MIN_TEMP            # Base threshold (°C)
MAX_TEMP=$MAX_TEMP            # Critical temperature (°C)
HYSTERESIS=$HYSTERESIS           # Temperature buffer (°C)
CHECK_INTERVAL=$CHECK_INTERVAL      # Base check interval (seconds)
TAPER_MINS=$TAPER_MINS          # Cool-down duration (minutes)
FAN_PWM_AUTODETECT=$FAN_PWM_AUTODETECT  # Auto-detect all active fan PWM channels
FAN_PWM_DEVICE="$FAN_PWM_DEVICE"  # Only used when FAN_PWM_AUTODETECT=false
OPTIMAL_PWM_FILE="$OPTIMAL_PWM_FILE"
MAX_PWM_STEP=$MAX_PWM_STEP        # Max PWM change per adjustment
DEADBAND=$DEADBAND             # Temp stability threshold (°C)
ALPHA=$ALPHA               # Smoothing factor (0-100)
LEARNING_RATE=$LEARNING_RATE        # PWM optimization step size
CONFIG
        logger -t fan-control "ERROR: Failed to write to temporary config file"
        # Continue with current in-memory values, but don't update the file
    elif ! mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to update config file with corrected values"
        rm -f "$temp_config" 2>/dev/null  # Clean up the temporary file
    else
        logger -t fan-control "CONFIG: Configuration file updated with corrected values"
    fi
fi

# Derived values
FAN_ACTIVATION_TEMP=$((MIN_TEMP + HYSTERESIS))
TAPER_DURATION=$((TAPER_MINS * 60))

###[ RUNTIME CHECKS ]##########################################################
# Check for ubnt-systool availability
if ! command -v ubnt-systool >/dev/null 2>&1; then
    logger -t fan-control "FATAL: ubnt-systool command not found"
    exit 1
fi

###[ PWM DEVICE DETECTION ]####################################################
# Detect all active fan PWM channels
# Populates the FAN_PWM_DEVICES array with writable PWM paths that have spinning fans
detect_pwm_devices() {
    local candidates=()
    local detected=()

    # Strategy 1: look for pwm files directly in hwmon class directories
    # Works on: UCG-Max (lm63 driver), UNVR (adt7475, kernel exposes class symlinks)
    for pwm_file in "$HWMON_BASE"/hwmon*/pwm[1-9]; do
        [[ -e "$pwm_file" ]] && candidates+=("$pwm_file")
    done

    # Strategy 2: if no class-level pwm files found, resolve via raw device paths
    # Needed for UDM-SE where adt7475 driver does not expose pwm in the class dir
    if [[ ${#candidates[@]} -eq 0 ]]; then
        logger -t fan-control "DETECT: No pwm in hwmon class dirs, falling back to raw device paths"
        for hwmon_dir in "$HWMON_BASE"/hwmon*; do
            local dev_path
            dev_path=$(readlink -f "$hwmon_dir/device" 2>/dev/null) || continue
            for pwm_file in "$dev_path"/pwm[1-9]; do
                [[ -e "$pwm_file" ]] && candidates+=("$pwm_file")
            done
        done
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        logger -t fan-control "FATAL: No PWM devices found in /sys"
        exit 1
    fi

    # Filter candidates to channels that are writable and have a spinning fan
    for pwm_file in "${candidates[@]}"; do
        local pwm_dir
        pwm_dir=$(dirname "$pwm_file")
        local pwm_name
        pwm_name=$(basename "$pwm_file")
        local fan_num="${pwm_name#pwm}"
        local fan_input="${pwm_dir}/fan${fan_num}_input"
        local rpm=0

        [[ -f "$fan_input" ]] && rpm=$(cat "$fan_input" 2>/dev/null || echo 0)

        # Test actual writability by writing the current value back
        # (sysfs file permissions are unreliable — a file may show 644 but still be writable by root)
        local current_val
        current_val=$(cat "$pwm_file" 2>/dev/null) || continue
        if ! echo "$current_val" > "$pwm_file" 2>/dev/null; then
            logger -t fan-control "DETECT: ${pwm_file} not writable, skipping"
            continue
        fi

        if (( rpm > 0 )); then
            detected+=("$pwm_file")
            logger -t fan-control "DETECT: ${pwm_file} -> fan${fan_num} = ${rpm} RPM (active)"
        else
            logger -t fan-control "DETECT: ${pwm_file} -> fan${fan_num} = 0 RPM (skipped)"
        fi
    done

    # If no fans were spinning, fall back to all writable PWM channels
    # (handles cold boot or devices where fans only spin when PWM > 0)
    if [[ ${#detected[@]} -eq 0 ]]; then
        logger -t fan-control "DETECT: No spinning fans found, using all writable PWM channels"
        for pwm_file in "${candidates[@]}"; do
            local current_val
            current_val=$(cat "$pwm_file" 2>/dev/null) || continue
            echo "$current_val" > "$pwm_file" 2>/dev/null && detected+=("$pwm_file")
        done
    fi

    if [[ ${#detected[@]} -eq 0 ]]; then
        logger -t fan-control "FATAL: No writable PWM devices found"
        exit 1
    fi

    FAN_PWM_DEVICES=("${detected[@]}")
    logger -t fan-control "DETECT: Controlling ${#FAN_PWM_DEVICES[@]} fan(s): ${FAN_PWM_DEVICES[*]}"
}

# Determine PWM devices to control
FAN_PWM_DEVICES=()
if [[ "$FAN_PWM_AUTODETECT" != "false" ]]; then
    detect_pwm_devices
else
    # Manual override — validate the configured single device
    logger -t fan-control "DETECT: Auto-detect disabled, using configured device: $FAN_PWM_DEVICE"
    _current_val=$(cat "$FAN_PWM_DEVICE" 2>/dev/null) || {
        logger -t fan-control "FATAL: PWM device $FAN_PWM_DEVICE not readable"
        exit 1
    }
    if ! echo "$_current_val" > "$FAN_PWM_DEVICE" 2>/dev/null; then
        logger -t fan-control "FATAL: PWM device $FAN_PWM_DEVICE not writable"
        exit 1
    fi
    unset _current_val
    FAN_PWM_DEVICES=("$FAN_PWM_DEVICE")
fi

# Ensure directories for state files exist
mkdir -p "$(dirname "$TEMP_STATE_FILE")" "$(dirname "$OPTIMAL_PWM_FILE")" || {
    logger -t fan-control "FATAL: Failed to create required directories"
    exit 1
}

# Single instance lock + cleanup — FD held for the daemon's lifetime
# flock is the authoritative guard; stale PID ps-checks can false-positive on PID reuse.
PID_FILE="${FAN_CONTROL_PID_FILE:-/var/run/fan-control.pid}"

cleanup() {
    for _d in "${FAN_PWM_DEVICES[@]}"; do
        echo 0 > "$_d" 2>/dev/null
    done
    rm -f "$PID_FILE" 2>/dev/null
}

# Open the lock FD WITHOUT truncating (>>) so a running instance's PID isn't clobbered
exec 200>>"$PID_FILE"
if ! flock -n 200; then
    logger -t fan-control "ALERT: Another instance already holds the lock (PID $(cat "$PID_FILE" 2>/dev/null))"
    exit 1
fi
echo $$ > "$PID_FILE"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

###[ CORE FUNCTIONALITY ]######################################################
# State definitions
STATE_OFF=0        # Fan completely off
STATE_TAPER=1      # Cooling down period before turning off
STATE_ACTIVE=2     # Normal operation with temperature-based fan speed
STATE_EMERGENCY=3  # Critical temperature, maximum fan speed

# Runtime variables
CURRENT_STATE=$STATE_OFF
TAPER_START=0      # Timestamp when taper mode started
LAST_PWM=-1        # Last PWM value set
SMOOTHED_TEMP=50   # Current smoothed temperature
LAST_ADJUSTMENT=0  # Timestamp of last PWM optimization
LAST_AVG_TEMP=0    # Previous temperature (for deadband calculations)
TEMP_READ_FAILURES=0  # Track consecutive temperature reading failures

# Function to safely write to a file using atomic operations
atomic_write_file() {
    local target_file="$1"
    local content="$2"
    local temp_file="${target_file}.tmp"

    if ! echo "$content" > "$temp_file" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to write to temporary file for $target_file"
        return 1
    elif ! mv "$temp_file" "$target_file" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to update file $target_file"
        rm -f "$temp_file" 2>/dev/null  # Clean up the temporary file
        return 1
    fi
    return 0
}

# Initialize smoothed temp from state file or raw temp
raw_temp=$(ubnt-systool cputemp | awk '{print int($1)}' || echo 50)
if [[ -f "$TEMP_STATE_FILE" ]]; then
    saved_temp=$(cat "$TEMP_STATE_FILE" 2>/dev/null)
    # Validate saved temperature is a number and within reasonable range
    if [[ "$saved_temp" =~ ^[0-9]+$ ]] && (( saved_temp >= 20 && saved_temp <= 100 )); then
        # Don't use saved temp if it's too far from current raw temp (prevents large jumps)
        # Compute the real absolute difference |saved - raw| — the previous
        # `${saved_temp#-} - ${raw_temp#-}` form only stripped a leading minus
        # from each operand independently and did NOT take |saved - raw|, so a
        # hot restart with a stale low saved temp (raw > saved) always passed
        # the < 15 guard and re-initialised SMOOTHED_TEMP to the stale value,
        # potentially keeping the fan OFF on a hot boot until the next loop tick.
        init_delta=$(( saved_temp - raw_temp ))
        (( init_delta < 0 )) && init_delta=$(( -init_delta ))
        if (( init_delta < 15 )); then
            SMOOTHED_TEMP=$saved_temp
            logger -t fan-control "INIT: Loaded saved temp=${SMOOTHED_TEMP}°C | Raw=${raw_temp}°C"
        else
            SMOOTHED_TEMP=$raw_temp
            logger -t fan-control "INIT: Discarded saved temp=${saved_temp}°C (too far from raw=${raw_temp}°C)"
        fi
    else
        SMOOTHED_TEMP=$raw_temp
        logger -t fan-control "INIT: Invalid saved temp=${saved_temp}°C, using raw=${raw_temp}°C"
    fi
else
    SMOOTHED_TEMP=$raw_temp
    logger -t fan-control "INIT: No saved temp, using raw=${raw_temp}°C"
fi

# MUST be called directly, never via $(...) — state must persist in the parent shell.
get_smoothed_temp() {
    local raw_temp_output=$(ubnt-systool cputemp 2>/dev/null)
    local raw_temp

    # Check if we got valid output
    if [[ -z "$raw_temp_output" ]] || ! [[ "$raw_temp_output" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        TEMP_READ_FAILURES=$((TEMP_READ_FAILURES + 1))
        logger -t fan-control "ERROR: Failed to read temperature (attempt $TEMP_READ_FAILURES)"
        # Use last known temperature — fail-safe decision is in update_fan_state
        raw_temp=$SMOOTHED_TEMP
    else
        # Reset failure counter on successful read
        TEMP_READ_FAILURES=0
        raw_temp=$(echo "$raw_temp_output" | awk '{print int($1)}')
    fi

    # Ensure we have a valid temperature value
    raw_temp=${raw_temp:-50}
    local previous=$SMOOTHED_TEMP

    # Calculate new smoothed temperature using exponential smoothing formula:
    # smoothed_temp = (α × previous_smooth + (100 - α) × raw_temp) / 100
    # where α (ALPHA) controls how much weight to give to previous vs. new readings
    # Use awk for floating-point arithmetic to prevent drift from integer rounding
    SMOOTHED_TEMP=$(awk "BEGIN { printf \"%.0f\", ($ALPHA * $SMOOTHED_TEMP + (100 - $ALPHA) * $raw_temp) / 100 }")

    # Safety check: If raw and smoothed temps differ by more than 20°C, reset smoothed temp
    local temp_diff=$((raw_temp - SMOOTHED_TEMP))
    if (( ${temp_diff#-} > 20 )); then
        logger -t fan-control "ALERT: Large temp difference detected (${temp_diff}°C) - resetting smoothed temp"
        SMOOTHED_TEMP=$raw_temp
    fi

    # Save smoothed temp to state file (only if it changed significantly)
    if (( ${SMOOTHED_TEMP#-} - ${previous#-} != 0 )); then
        atomic_write_file "$TEMP_STATE_FILE" "$SMOOTHED_TEMP"
    fi

    logger -t fan-control "TEMP:  RAW=${raw_temp}°C | SMOOTH=${SMOOTHED_TEMP}°C | DELTA=$((raw_temp - SMOOTHED_TEMP))°C"
}

calculate_speed() {
    local avg_temp=$1
    local temp_range=$((MAX_TEMP - FAN_ACTIVATION_TEMP))
    local temp_diff=$((avg_temp - FAN_ACTIVATION_TEMP))

    # Prevent division by zero
    (( temp_range > 0 )) || temp_range=1

    # Quadratic response curve calculation:
    # PWM = MIN_PWM + (temp_diff²/temp_range²) * (MAX_PWM - MIN_PWM)
    # The formula is multiplied by 20 and divided by 10 to improve integer math precision
    local speed=$(( (temp_diff * temp_diff * (MAX_PWM - MIN_PWM) * 20) / (temp_range * temp_range * 10) ))
    speed=$(( speed + MIN_PWM ))

    # Ensure speed doesn't exceed MAX_PWM
    speed=$(( speed > MAX_PWM ? MAX_PWM : speed ))

    logger -t fan-control "CALC: temp_diff=${temp_diff}°C | range=${temp_range}°C | speed=${speed}pwm"
    echo $speed
}

# Speed control with logging
set_fan_speed() {
    local new_speed=$1
    local current_temp=$SMOOTHED_TEMP
    local reason="Normal operation"

    # Emergency override
    if (( current_temp >= MAX_TEMP )); then
        new_speed=$MAX_PWM
        reason="EMERGENCY: Temp ${current_temp}°C ≥ ${MAX_TEMP}°C"
    fi

    # Special handling for OFF state
    if (( CURRENT_STATE == STATE_OFF )); then
        new_speed=0  # Force 0 PWM regardless of other logic
        reason="OFF state override"
    else
        # Apply ramp limits only in non-OFF states
        if (( new_speed > LAST_PWM + MAX_PWM_STEP )); then
            reason="Ramp-up limited: ${LAST_PWM}→$((LAST_PWM + MAX_PWM_STEP))pwm"
            new_speed=$(( LAST_PWM + MAX_PWM_STEP ))
        elif (( new_speed < LAST_PWM - MAX_PWM_STEP )); then
            reason="Ramp-down limited: ${LAST_PWM}→$((LAST_PWM - MAX_PWM_STEP))pwm"
            new_speed=$(( LAST_PWM - MAX_PWM_STEP ))
        fi

        # Enforce MIN/MAX only in active states
        new_speed=$(( new_speed > MAX_PWM ? MAX_PWM : new_speed ))
        new_speed=$(( new_speed < MIN_PWM ? MIN_PWM : new_speed ))
    fi

    if [[ "$new_speed" -ne "$LAST_PWM" ]]; then
        # Note: Due to hardware limitations, the actual PWM value applied may differ from the requested value
        # (e.g., setting 50 might result in ~48, or 100 might result in ~92)
        local write_ok=true
        for pwm_dev in "${FAN_PWM_DEVICES[@]}"; do
            if ! echo "$new_speed" > "$pwm_dev" 2>/dev/null; then
                logger -t fan-control "ERROR: Failed to write to PWM device $pwm_dev"
                if [[ ! -e "$pwm_dev" ]]; then
                    logger -t fan-control "FATAL: PWM device $pwm_dev no longer exists"
                fi
                write_ok=false
            fi
        done
        if [[ "$write_ok" = true ]]; then
            logger -t fan-control "SET: ${LAST_PWM}→${new_speed}pwm | Reason: ${reason}"
            LAST_PWM=$new_speed
            LAST_AVG_TEMP=$current_temp  # Reset deadband tracking on change
        fi

        if (( CURRENT_STATE == STATE_ACTIVE )); then
            local now=$(date +%s)
            # More frequent learning for better adaptation (30 minutes instead of 1 hour)
            # Check if it's time to adjust the optimal PWM value (every 30 minutes)
            if (( now - LAST_ADJUSTMENT > 1800 )); then
                local optimal=$(cat "$OPTIMAL_PWM_FILE" 2>/dev/null || echo "$MIN_PWM")
                # Validate optimal PWM value
                if ! [[ "$optimal" =~ ^[0-9]+$ ]] || (( optimal < MIN_PWM || optimal > MAX_PWM )); then
                    logger -t fan-control "WARNING: Invalid optimal PWM value: ${optimal}, using MIN_PWM"
                    optimal=$MIN_PWM
                fi
                local original_optimal=$optimal
                local adjustment=""
                local adaptive_rate=$LEARNING_RATE

                # Calculate temperature change and stability over time
                local temp_delta=$(( current_temp - LAST_AVG_TEMP ))
                local temp_stability=${temp_delta#-}  # Use absolute value of temp_delta

                # Adjust learning rate based on temperature stability
                # More stable temperatures allow for more aggressive learning
                if (( temp_stability < DEADBAND )); then
                    # Temperature is stable, can use higher learning rate
                    adaptive_rate=$(( LEARNING_RATE + 2 ))
                elif (( temp_stability > DEADBAND * 3 )); then
                    # Temperature is fluctuating a lot, use lower learning rate
                    adaptive_rate=$(( LEARNING_RATE - 1 ))
                    adaptive_rate=$(( adaptive_rate < 1 ? 1 : adaptive_rate ))
                fi

                # Enhanced learning logic with more responsive adjustments
                # 1. If we're at optimal speed but temp is rising, increase PWM
                # 2. If we're at optimal speed but temp is stable below MIN_TEMP, decrease PWM
                # 3. If we're above optimal speed but temp is stable, try to decrease PWM
                # 4. If temperature is rising rapidly, make larger adjustments
                if (( new_speed == optimal )); then
                    if (( temp_delta > 0 && current_temp > MIN_TEMP )); then
                        # Temperature rising, increase PWM proactively
                        # Scale adjustment based on how quickly temperature is rising
                        local rise_factor=$(( temp_delta > 2 ? 2 : 1 ))
                        local adj_amount=$(( adaptive_rate * rise_factor ))
                        adjustment="+${adj_amount} (rising temp ${temp_delta}°C)"
                        optimal=$(( optimal + adj_amount ))
                    elif (( current_temp < MIN_TEMP && temp_stability < DEADBAND * 2 )); then
                        # Temperature below threshold and stable, can reduce PWM
                        adjustment="-${adaptive_rate} (stable below threshold)"
                        optimal=$(( optimal - adaptive_rate ))
                    fi
                elif (( new_speed > optimal && temp_stability < DEADBAND && current_temp < MIN_TEMP + HYSTERESIS )); then
                    # We're running faster than optimal but temp is stable and not too high
                    # Try to gradually reduce optimal PWM to find the most efficient setting
                    adjustment="-1 (efficiency optimization)"
                    optimal=$(( optimal - 1 ))
                # If we're below optimal speed but temperature is rising quickly
                elif (( new_speed < optimal && temp_delta > DEADBAND * 2 )); then
                    # Temperature rising quickly while below optimal speed - increase optimal
                    adjustment="+${adaptive_rate} (rapid temp increase ${temp_delta}°C)"
                    optimal=$(( optimal + adaptive_rate ))
                fi

                if [[ -n "$adjustment" ]]; then
                    # Ensure optimal PWM stays within valid range
                    optimal=$(( optimal > MAX_PWM ? MAX_PWM : optimal ))
                    optimal=$(( optimal < MIN_PWM ? MIN_PWM : optimal ))

                    # Use atomic write function to update the optimal PWM file
                    if atomic_write_file "$OPTIMAL_PWM_FILE" "$optimal"; then
                        LAST_ADJUSTMENT=$now
                        logger -t fan-control "LEARNING: ${original_optimal}→${optimal}pwm (${adjustment}) [Rate=${adaptive_rate}]"
                    fi
                fi
            fi
        fi
    fi
}

###[ MQTT INTEGRATION (OPTIONAL) ]#############################################
# Everything in this section is a no-op when MQTT_ENABLED=false (the default),
# so fan-control.sh behaves exactly like upstream when MQTT is not configured.
MQTT_DEVICE_ID="$(hostname 2>/dev/null | tr -c 'a-zA-Z0-9_-' '-')"
[[ -z "$MQTT_DEVICE_ID" ]] && MQTT_DEVICE_ID="unifi-fan-control"
MQTT_STATE_TOPIC="${MQTT_BASE_TOPIC}/${MQTT_DEVICE_ID}/state"
MQTT_WARNED_MISSING_CLIENT=false

# Current MQTT-driven mode, refreshed every loop iteration from MQTT_MODE_FILE.
# Defaults to "auto" so behavior is identical to upstream unless mqtt-control.sh
# has explicitly switched to "manual".
MQTT_MODE="auto"
MQTT_MANUAL_PWM_PERCENT=0
MQTT_LIB_LOADED=false

# Lazily source the pure-Bash MQTT client library the first time it's needed.
_mqtt_ensure_lib_loaded() {
    [[ "$MQTT_LIB_LOADED" == true ]] && return 0

    if [[ ! -f "$MQTT_LIB_FILE" ]]; then
        if [[ "$MQTT_WARNED_MISSING_CLIENT" == false ]]; then
            logger -t fan-control "MQTT: mqtt-lib.sh not found at $MQTT_LIB_FILE - MQTT publishing disabled"
            MQTT_WARNED_MISSING_CLIENT=true
        fi
        return 1
    fi

    # shellcheck source=mqtt-lib.sh
    source "$MQTT_LIB_FILE"
    MQTT_LIB_LOADED=true
    return 0
}

# Publish a single message to the MQTT broker using the pure-Bash MQTT client
# (mqtt-lib.sh). Opens a short-lived connection per publish - simple and
# robust for this project's low-frequency (once per CHECK_INTERVAL) telemetry.
# Silently returns if MQTT_ENABLED is not "true" or the library is unavailable.
mqtt_publish() {
    local topic="$1"
    local payload="$2"
    local retain_flag="$3"  # "retain" to set the MQTT retain flag, empty otherwise

    [[ "$MQTT_ENABLED" == "true" ]] || return 0
    _mqtt_ensure_lib_loaded || return 1

    if ! mqtt_lib_connect "$MQTT_HOST" "$MQTT_PORT" "${MQTT_DEVICE_ID}-fc" "$MQTT_USER" "$MQTT_PASSWORD" 30; then
        logger -t fan-control "MQTT: Connect failed ($MQTT_LIB_LAST_ERROR) - skipping publish to $topic"
        return 1
    fi

    if ! mqtt_lib_publish "$topic" "$payload" "$retain_flag"; then
        logger -t fan-control "MQTT: Failed to publish to $topic"
        mqtt_lib_disconnect
        return 1
    fi

    mqtt_lib_disconnect
    return 0
}

# Publish the current controller state as a JSON payload. Called once per loop
# iteration when MQTT_ENABLED=true.
mqtt_publish_state() {
    [[ "$MQTT_ENABLED" == "true" ]] || return 0

    local state_name
    if [[ "$MQTT_MODE" == "manual" ]]; then
        # The auto state machine (OFF/TAPER/ACTIVE/EMERGENCY) is bypassed
        # entirely in manual mode and CURRENT_STATE is left frozen at
        # whatever it was before the switch, so report "MANUAL" here instead
        # of a stale/misleading auto-state name.
        state_name="MANUAL"
    else
        state_name=$(get_state_name "$CURRENT_STATE")
    fi
    local payload
    payload=$(printf '{"state":"%s","mode":"%s","temp_smooth":%s,"pwm":%s,"pwm_percent":%s}' \
        "$state_name" "$MQTT_MODE" "$SMOOTHED_TEMP" "$LAST_PWM" \
        "$(( (LAST_PWM * 100 + 127) / 255 ))")

    mqtt_publish "$MQTT_STATE_TOPIC" "$payload" "retain"
}

# Reload the manual/auto mode written by mqtt-control.sh. The file uses simple
# KEY=VALUE lines (MODE=auto|manual, MANUAL_PWM_PERCENT=0-100) so it can be
# written atomically and read cheaply every loop iteration.
mqtt_load_mode() {
    [[ "$MQTT_ENABLED" == "true" ]] || return 0
    [[ -f "$MQTT_MODE_FILE" ]] || return 0

    local file_mode="" file_pwm=""
    while IFS='=' read -r key value; do
        case "$key" in
            MODE) file_mode="$value" ;;
            MANUAL_PWM_PERCENT) file_pwm="$value" ;;
        esac
    done < "$MQTT_MODE_FILE" 2>/dev/null

    if [[ "$file_mode" == "auto" || "$file_mode" == "manual" ]]; then
        MQTT_MODE="$file_mode"
    fi
    if [[ "$file_pwm" =~ ^[0-9]+$ ]] && (( file_pwm >= 0 && file_pwm <= 100 )); then
        MQTT_MANUAL_PWM_PERCENT=$file_pwm
    fi
}

# Apply the manual PWM percentage directly to every detected fan channel,
# bypassing the state machine, ramp limits, MIN/MAX enforcement and the
# EMERGENCY fail-safe entirely. This is an explicit user choice: in manual
# mode the fan stays exactly at the requested speed, with no automatic
# override, even at critical temperatures.
apply_manual_pwm() {
    local percent=$MQTT_MANUAL_PWM_PERCENT
    local pwm=$(( (percent * 255 + 50) / 100 ))
    (( pwm > 255 )) && pwm=255
    (( pwm < 0 )) && pwm=0

    if [[ "$pwm" -ne "$LAST_PWM" ]]; then
        local write_ok=true
        for pwm_dev in "${FAN_PWM_DEVICES[@]}"; do
            if ! echo "$pwm" > "$pwm_dev" 2>/dev/null; then
                logger -t fan-control "ERROR: Failed to write to PWM device $pwm_dev (manual mode)"
                write_ok=false
            fi
        done
        if [[ "$write_ok" = true ]]; then
            logger -t fan-control "MANUAL: ${LAST_PWM}→${pwm}pwm (${percent}%) | No EMERGENCY failsafe in manual mode"
            LAST_PWM=$pwm
        fi
    fi
}

###[ STATE MANAGEMENT ]########################################################
update_fan_state() {
    get_smoothed_temp
    local avg_temp=$SMOOTHED_TEMP
    local now=$(date +%s)
    local state_transition=""

    # Sensor fail-safe: write MAX_PWM directly, bypassing state machine and ramp
    # limits (the OFF-state override in set_fan_speed would force 0).
    if (( TEMP_READ_FAILURES >= 3 )); then
        if (( LAST_PWM != MAX_PWM )); then
            logger -t fan-control "ALERT: Sensor fail-safe active (${TEMP_READ_FAILURES} consecutive read failures) - forcing MAX_PWM"
        fi
        for pwm_dev in "${FAN_PWM_DEVICES[@]}"; do
            echo "$MAX_PWM" > "$pwm_dev" 2>/dev/null
        done
        LAST_PWM=$MAX_PWM
        CURRENT_STATE=$STATE_ACTIVE   # so recovery re-evaluates from a sane state
        return
    fi

    # Check for emergency condition first
    if (( avg_temp >= MAX_TEMP )); then
        if (( CURRENT_STATE != STATE_EMERGENCY )); then
            state_transition="→EMERGENCY (${avg_temp}°C ≥ ${MAX_TEMP}°C)"
            CURRENT_STATE=$STATE_EMERGENCY
            set_fan_speed $MAX_PWM
        else
            # Already in emergency state, ensure max fan speed
            set_fan_speed $MAX_PWM
        fi
    else
        # Normal state machine when not in emergency
        case $CURRENT_STATE in
            $STATE_EMERGENCY)
                # Exit emergency mode only when temperature drops significantly below MAX_TEMP
                if (( avg_temp <= MAX_TEMP - HYSTERESIS )); then
                    state_transition="EMERGENCY→ACTIVE (${avg_temp}°C ≤ $((MAX_TEMP - HYSTERESIS))°C)"
                    CURRENT_STATE=$STATE_ACTIVE
                    set_fan_speed $(calculate_speed $avg_temp)
                else
                    # Stay in emergency mode
                    set_fan_speed $MAX_PWM
                fi
                ;;

            $STATE_OFF)
                if (( avg_temp >= FAN_ACTIVATION_TEMP )); then
                    state_transition="OFF→ACTIVE (${avg_temp}°C ≥ ${FAN_ACTIVATION_TEMP}°C)"
                    CURRENT_STATE=$STATE_ACTIVE
                    set_fan_speed $OPTIMAL_PWM
                fi
                ;;

            $STATE_TAPER)
                if (( avg_temp >= FAN_ACTIVATION_TEMP + 2 )); then  # Added 2°C buffer to prevent oscillation
                    state_transition="TAPER→ACTIVE (${avg_temp}°C ≥ $((FAN_ACTIVATION_TEMP + 2))°C)"
                    CURRENT_STATE=$STATE_ACTIVE
                    set_fan_speed $OPTIMAL_PWM
                elif (( now - TAPER_START >= TAPER_DURATION )); then
                    state_transition="TAPER→OFF (${TAPER_MINS}min elapsed)"
                    CURRENT_STATE=$STATE_OFF
                    set_fan_speed 0
                else
                    local remaining=$(( TAPER_DURATION - (now - TAPER_START) ))
                    logger -t fan-control "TAPER: Remaining $((remaining / 60))m | Current: ${avg_temp}°C"
                    set_fan_speed $MIN_PWM
                fi
                ;;

            $STATE_ACTIVE)
                if (( avg_temp <= MIN_TEMP )); then
                    state_transition="ACTIVE→TAPER (${avg_temp}°C ≤ ${MIN_TEMP}°C)"
                    CURRENT_STATE=$STATE_TAPER
                    TAPER_START=$now
                    set_fan_speed $MIN_PWM
                else
                    local temp_delta=$(( avg_temp - LAST_AVG_TEMP ))
                    if (( ${temp_delta#-} > DEADBAND )); then
                        logger -t fan-control "DEADBAND:  DELTA=${temp_delta}°C | THRESHOLD=${DEADBAND}°C"
                        local speed=$(calculate_speed $avg_temp)
                        set_fan_speed $speed
                    else
                        # Force adjustment if we're below target PWM
                        local target_speed=$(calculate_speed $avg_temp)
                        if (( LAST_PWM < target_speed )); then
                            logger -t fan-control "DEADBAND:  Forcing adjustment (current ${LAST_PWM}pwm < target ${target_speed}pwm)"
                            set_fan_speed $target_speed
                        else
                            logger -t fan-control "DEADBAND:  No change | DELTA=${temp_delta}°C"
                        fi
                    fi
                fi
                ;;
        esac
    fi

    [[ -n "$state_transition" ]] && logger -t fan-control "STATE: ${state_transition}"
}

###[ MAIN EXECUTION ]##########################################################
# Initialize optimal PWM file if it doesn't exist
[[ -f "$OPTIMAL_PWM_FILE" ]] || {
    if atomic_write_file "$OPTIMAL_PWM_FILE" "$MIN_PWM"; then
        logger -t fan-control "INIT: Created optimal PWM file with ${MIN_PWM}pwm"
    fi
}

# Read and validate optimal PWM value
OPTIMAL_PWM=$(cat "$OPTIMAL_PWM_FILE" 2>/dev/null || echo "$MIN_PWM")
if ! [[ "$OPTIMAL_PWM" =~ ^[0-9]+$ ]] || (( OPTIMAL_PWM < MIN_PWM || OPTIMAL_PWM > MAX_PWM )); then
    logger -t fan-control "WARNING: Invalid optimal PWM value: ${OPTIMAL_PWM}, using MIN_PWM"
    OPTIMAL_PWM=$MIN_PWM

    # Write corrected value back to file
    if atomic_write_file "$OPTIMAL_PWM_FILE" "$OPTIMAL_PWM"; then
        logger -t fan-control "FIXED: Updated optimal PWM file with corrected value ${OPTIMAL_PWM}pwm"
    fi
fi
logger -t fan-control "START: Optimal=${OPTIMAL_PWM}pwm | Config: MIN=${MIN_TEMP}°C, MAX=${MAX_TEMP}°C, HYST=${HYSTERESIS}°C"

get_smoothed_temp
if (( SMOOTHED_TEMP >= FAN_ACTIVATION_TEMP )); then
    logger -t fan-control "COLDSTART: Initial temp ${SMOOTHED_TEMP}°C ≥ ${FAN_ACTIVATION_TEMP}°C"
    CURRENT_STATE=$STATE_ACTIVE
    set_fan_speed $OPTIMAL_PWM
else
    logger -t fan-control "COLDSTART: Initial temp ${SMOOTHED_TEMP}°C - Fans off"
    set_fan_speed 0
fi

# Define state names for more readable logging
get_state_name() {
    case $1 in
        $STATE_OFF) echo "OFF" ;;
        $STATE_TAPER) echo "TAPER" ;;
        $STATE_ACTIVE) echo "ACTIVE" ;;
        $STATE_EMERGENCY) echo "EMERGENCY" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# Main loop
declare -i loop_counter=0
PREVIOUS_MQTT_MODE="$MQTT_MODE"
while true; do
    mqtt_load_mode

    # When switching back from manual to auto, the state machine may believe
    # it is already in STATE_OFF (unchanged since manual mode bypassed it) and
    # would otherwise skip re-writing the PWM device, leaving the stale manual
    # value in place. Force a resync exactly like the cold-start path does.
    if [[ "$PREVIOUS_MQTT_MODE" == "manual" && "$MQTT_MODE" == "auto" ]]; then
        logger -t fan-control "MQTT: Mode switched manual→auto, resyncing fan state"
        CURRENT_STATE=$STATE_OFF
        set_fan_speed 0
    fi
    PREVIOUS_MQTT_MODE="$MQTT_MODE"

    if [[ "$MQTT_MODE" == "manual" ]]; then
        # Manual mode (set via Home Assistant): still track temperature for
        # telemetry, but bypass the state machine entirely - no EMERGENCY
        # failsafe override while manual mode is active (explicit user choice).
        get_smoothed_temp
        apply_manual_pwm
    else
        update_fan_state
    fi

    mqtt_publish_state

    # Log status every 10 iterations
    (( loop_counter++ % 10 == 0 )) && {
        if [[ "$MQTT_MODE" == "manual" ]]; then
            state_name="MANUAL"
        else
            state_name=$(get_state_name $CURRENT_STATE)
        fi
        current_temp=$SMOOTHED_TEMP
        logger -t fan-control "STATUS: State=${state_name} | Mode=${MQTT_MODE} | PWM=${LAST_PWM} | Temp=${current_temp}°C"
    }

    sleep $CHECK_INTERVAL
done
