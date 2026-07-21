#!/bin/bash
set -e

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

# Check for systemd availability
if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemd is required but not found"
    exit 1
fi

# Check for curl availability
if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not found"
    exit 1
fi

# Repository information
# NOTE: update REPO_OWNER/REPO_NAME if you publish this fork under a different
# GitHub account/repository name.
REPO_OWNER="${FAN_CONTROL_REPO_OWNER:-grausof}"
REPO_NAME="${FAN_CONTROL_REPO_NAME:-unifi-fan-control-mqtt}"
BRANCH="${FAN_CONTROL_BRANCH:-main}"  # Use environment variable if set, otherwise default to main
BASE_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH"

echo "Installing from branch: $BRANCH"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create directory for fan control
mkdir -p /data/fan-control || {
    echo "Error: Failed to create directory /data/fan-control"
    exit 1
}

# Check if directory is writable
if [ ! -w "/data/fan-control" ]; then
    echo "Error: Directory /data/fan-control is not writable"
    exit 1
fi

# Function to get a file from local directory or download from GitHub
get_file() {
    local filename="$1"
    local destination="$2"

    # Try to use local file first
    if [ -f "$SCRIPT_DIR/$filename" ]; then
        echo "Using local file: $filename"
        cp "$SCRIPT_DIR/$filename" "$destination"
    else
        echo "Downloading $filename from repository..."
        curl -sSL "$BASE_URL/$filename" -o "$destination"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to download $filename"
            exit 1
        fi
    fi
}

# Get fan control script
get_file "fan-control.sh" "/data/fan-control/fan-control.sh"
chmod +x /data/fan-control/fan-control.sh

# Get the pure-Bash MQTT client library (no mosquitto-clients dependency).
# Always deployed alongside fan-control.sh, even when MQTT stays disabled,
# so enabling it later only requires editing the config file.
get_file "mqtt-lib.sh" "/data/fan-control/mqtt-lib.sh"

# Get uninstall script
get_file "uninstall.sh" "/data/fan-control/uninstall.sh"
chmod +x /data/fan-control/uninstall.sh

# Install systemd service
SERVICE_FILE="/etc/systemd/system/fan-control.service"
get_file "fan-control.service" "$SERVICE_FILE"

# Verify service file was created
if [ ! -f "$SERVICE_FILE" ]; then
    echo "Error: Failed to create service file"
    exit 1
fi

# Configure systemd service
echo "Reloading systemd configuration..."
systemctl daemon-reload || {
    echo "Error: Failed to reload systemd configuration"
    exit 1
}

# Smart service management
if systemctl is-active --quiet fan-control.service; then
    echo "Service already running - performing hot update"
    if ! systemctl restart fan-control.service; then
        echo "Error: Failed to restart service"
        echo "Check service status with: systemctl status fan-control.service"
        exit 1
    fi
    echo "Service successfully updated and restarted"
else
    echo "Performing fresh installation"
    if ! systemctl enable --now fan-control.service; then
        echo "Error: Failed to enable and start service"
        echo "Check service status with: systemctl status fan-control.service"
        exit 1
    fi
    echo "Service successfully enabled and started"
fi

###[ OPTIONAL MQTT / HOME ASSISTANT INTEGRATION ]##############################
# MQTT is entirely optional. By default it stays disabled and fan-control.sh
# behaves exactly like upstream. Enable it here (or later by editing the
# config file and re-running this installer) to publish state to MQTT and
# control the fan from Home Assistant.
#
# No external MQTT client (mosquitto-clients) is required: UniFi OS devices
# have no package manager to install it with, so this integration uses a
# pure-Bash MQTT client (mqtt-lib.sh, plaintext MQTT only - no TLS).
CONFIG_FILE="/data/fan-control/config"

# Wait briefly for fan-control.sh to bootstrap the config file on first start.
for _ in 1 2 3 4 5; do
    [ -f "$CONFIG_FILE" ] && break
    sleep 1
done

# When installed via `curl | sudo bash`, stdin is curl's pipe, not the
# terminal, so `[ -t 0 ]` is false and interactive prompts would be silently
# skipped. Read from /dev/tty instead so prompts still work in that case;
# TTY="" only when there really is no terminal available (e.g. CI/cron).
TTY=""
if [ -r /dev/tty ]; then
    TTY="/dev/tty"
fi

enable_mqtt="${FAN_CONTROL_ENABLE_MQTT:-}"
if [ -z "$enable_mqtt" ] && [ -n "$TTY" ]; then
    read -r -p "Enable optional MQTT integration for Home Assistant? [y/N]: " answer <"$TTY"
    case "$answer" in
        [Yy]*) enable_mqtt="true" ;;
        *) enable_mqtt="false" ;;
    esac
fi
enable_mqtt="${enable_mqtt:-false}"

# Update a KEY=VALUE (optionally quoted) line in the config file, preserving
# any trailing inline comment.
set_config_value() {
    local key="$1"
    local value="$2"
    local quoted="$3"  # "quoted" to wrap value in double quotes, empty otherwise

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Warning: Config file not found, cannot set $key"
        return 1
    fi
    if [ "$quoted" = "quoted" ]; then
        sed -i -E "s|^(${key}=)\"[^\"]*\"|\1\"${value}\"|" "$CONFIG_FILE"
    else
        sed -i -E "s|^(${key}=)[^ ]*|\1${value}|" "$CONFIG_FILE"
    fi
}

if [ "$enable_mqtt" = "true" ]; then
    echo "Configuring MQTT integration..."

    mqtt_host="${FAN_CONTROL_MQTT_HOST:-}"
    if [ -z "$mqtt_host" ] && [ -n "$TTY" ]; then
        read -r -p "MQTT broker host [127.0.0.1]: " mqtt_host <"$TTY"
    fi
    mqtt_host="${mqtt_host:-127.0.0.1}"

    mqtt_port="${FAN_CONTROL_MQTT_PORT:-}"
    if [ -z "$mqtt_port" ] && [ -n "$TTY" ]; then
        read -r -p "MQTT broker port [1883]: " mqtt_port <"$TTY"
    fi
    mqtt_port="${mqtt_port:-1883}"

    mqtt_user="${FAN_CONTROL_MQTT_USER:-}"
    if [ -z "$mqtt_user" ] && [ -n "$TTY" ]; then
        read -r -p "MQTT username (leave empty for none): " mqtt_user <"$TTY"
    fi

    mqtt_password="${FAN_CONTROL_MQTT_PASSWORD:-}"
    if [ -z "$mqtt_password" ] && [ -n "$TTY" ]; then
        read -r -s -p "MQTT password (leave empty for none): " mqtt_password <"$TTY"
        echo
    fi

    set_config_value "MQTT_ENABLED" "true"
    set_config_value "MQTT_HOST" "$mqtt_host" "quoted"
    set_config_value "MQTT_PORT" "$mqtt_port"
    set_config_value "MQTT_USER" "$mqtt_user" "quoted"
    set_config_value "MQTT_PASSWORD" "$mqtt_password" "quoted"

    # Deploy and start the MQTT command listener service
    get_file "mqtt-control.sh" "/data/fan-control/mqtt-control.sh"
    chmod +x /data/fan-control/mqtt-control.sh

    MQTT_SERVICE_FILE="/etc/systemd/system/mqtt-control.service"
    get_file "mqtt-control.service" "$MQTT_SERVICE_FILE"

    systemctl daemon-reload || {
        echo "Error: Failed to reload systemd configuration"
        exit 1
    }

    echo "Restarting fan-control.service to apply MQTT configuration..."
    systemctl restart fan-control.service || {
        echo "Error: Failed to restart fan-control.service"
        exit 1
    }

    if systemctl is-active --quiet mqtt-control.service; then
        systemctl restart mqtt-control.service
    else
        systemctl enable --now mqtt-control.service || {
            echo "Error: Failed to enable and start mqtt-control.service"
            echo "Check service status with: systemctl status mqtt-control.service"
            exit 1
        }
    fi
    echo "MQTT integration enabled. Home Assistant entities should appear automatically via MQTT Discovery."
else
    echo "Skipping MQTT integration (default). Enable it later by re-running this installer"
    echo "or by setting MQTT_ENABLED=true in $CONFIG_FILE and installing mqtt-control.service manually."
fi

echo "Installation successful!"
echo "Configuration: nano /data/fan-control/config"
echo "Status check: journalctl -u fan-control.service -f"
if [ "$enable_mqtt" = "true" ]; then
    echo "MQTT status check: journalctl -u mqtt-control.service -f"
fi
