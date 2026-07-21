# UniFi Intelligent Fan Control with MQTT and Home Assistant integration

Advanced temperature management for Ubiquiti UniFi OS devices with fan control, with an
**optional** MQTT / Home Assistant integration layered on top.

<img width="677" height="546" alt="Home Assistant screenshot" src="https://github.com/user-attachments/assets/10364ace-46d2-401b-a267-57d0e4289cb3" />

> This is a community fork of [iceteaSA/unifi-fan-control](https://github.com/iceteaSA/unifi-fan-control),
> adding optional MQTT publishing and Home Assistant control (auto/manual mode, manual PWM
> slider) while keeping the original temperature control logic unchanged.

Confirmed working on: UCG-Max, UCG-Fibre, UXG-Fibre, UDM-SE, UDM-Pro-Max, UDR7, UNVR

> This project is built and maintained independently. If it keeps your UniFi gear cool and quiet, [consider supporting the original project](https://ko-fi.com/H2H719VB0U).

## Features
- 🎛️ **Four Operational States**:
  - **OFF**: Fan disabled (temp < activation threshold)
  - **TAPER**: Post-cooling minimum speed period
  - **ACTIVE**: Quadratic response curve (temp ≥ activation threshold)
  - **EMERGENCY**: Immediate full speed (255 PWM) (critical temps)
- 🚨 **Emergency Override**: Instant full speed at critical temps with hysteresis for stable transitions
- 📈 **Quadratic Response**: Progressive cooling curve for optimal noise/performance
- 🧠 **Enhanced Adaptive Learning**: Intelligent PWM optimization with temperature trend analysis
- 📉 **Exponential Smoothing**: Noise-resistant temperature tracking
- 🛡️ **Robust Safety Systems**:
  - Speed limits and thermal protection
  - Hardware validation
  - Sensor failure detection and recovery
  - Configuration validation
- 🔄 **State Transition Hysteresis**: Prevents rapid state oscillation
- 🔍 **Multi-Fan Auto-Detection**: Automatically discovers and controls all active fan channels
  - Searches hwmon class directories first (UCG-Max, UNVR)
  - Falls back to raw sysfs device paths when needed (UDM-SE)
  - Identifies active fans by RPM reading and write-tests each channel
  - All detected fans receive the same PWM value
- 📡 **Optional MQTT / Home Assistant integration** (disabled by default):
  - Publishes controller state, temperature and PWM to MQTT every cycle
  - Home Assistant MQTT Discovery: sensors, an Auto Mode switch, and a Manual PWM slider
    appear automatically, no manual HA configuration needed
  - Manual mode lets you fully take over fan speed (0-100%) from Home Assistant,
    bypassing the automatic controller entirely
  - No external MQTT client required: implemented as a pure-Bash MQTT client
    (`mqtt-lib.sh`), since UniFi OS devices have no package manager to install
    `mosquitto-clients` with

## Installation
```bash
curl -sSL https://raw.githubusercontent.com/grausof/unifi-fan-control-mqtt/main/install.sh | sudo bash
```

### Using a Different Branch
If you want to install from a specific branch (e.g., for testing new features):

**Method 1: Direct URL**
```bash
# Replace 'dev' with your desired branch name
curl -sSL https://raw.githubusercontent.com/grausof/unifi-fan-control-mqtt/dev/install.sh | sudo bash
```

**Method 2: Environment Variable**
```bash
# Set the branch name via environment variable
FAN_CONTROL_BRANCH=dev curl -sSL https://raw.githubusercontent.com/grausof/unifi-fan-control-mqtt/main/install.sh | sudo bash
```

### Manual Installation
If you prefer to inspect the code before installation:
```bash
# Clone the repository
git clone https://github.com/grausof/unifi-fan-control-mqtt.git
cd unifi-fan-control-mqtt

# Optionally checkout a specific branch
# git checkout dev

# Run the installer (you can also use FAN_CONTROL_BRANCH to override the branch)
sudo ./install.sh
# Or with a specific branch:
# sudo FAN_CONTROL_BRANCH=dev ./install.sh
```

During installation you will be asked whether to enable the optional MQTT integration
(see [MQTT / Home Assistant Integration](#mqtt--home-assistant-integration-optional) below).
Answering "no" (the default) installs and behaves exactly like the upstream project.

## Configuration
Edit `/data/fan-control/config`:
```bash
# Core Thresholds
MIN_TEMP=60            # Base threshold (°C)
MAX_TEMP=85            # Critical temperature (°C)
HYSTERESIS=5           # Temperature buffer (°C)

# Fan Behavior
MIN_PWM=91        # Minimum active speed (0-255)
MAX_PWM=255       # Maximum speed (0-255)
MAX_PWM_STEP=25   # Maximum speed change per adjustment
                  # Note: Due to hardware limitations, actual PWM values may vary slightly from requested values

# Advanced Tuning
ALPHA=20          # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100 raw→smooth)
DEADBAND=1        # Temperature stability threshold (°C)
LEARNING_RATE=5   # Hourly PWM optimization step size
TAPER_MINS=90     # Cool-down duration (minutes)
CHECK_INTERVAL=15 # Temperature check frequency (seconds)

# Auto-detects all active fan channels by default (recommended)
# Set to false to use FAN_PWM_DEVICE as a single manual override instead
FAN_PWM_AUTODETECT=true
# Only used when FAN_PWM_AUTODETECT=false
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="/data/fan-control/optimal_pwm"

# Optional MQTT integration - disabled by default, see the dedicated section below
MQTT_ENABLED=false
MQTT_HOST="127.0.0.1"
MQTT_PORT=1883
MQTT_USER=""
MQTT_PASSWORD=""
MQTT_BASE_TOPIC="unifi-fan-control"
MQTT_DISCOVERY_PREFIX="homeassistant"
```

> **Note**: The script automatically checks for missing configuration parameters and adds them with default values if they're not present in the config file. This ensures that all required parameters are always available, even if you've edited the config file manually.

Apply changes:
```bash
systemctl restart fan-control.service
```

## Operational Overview
| State       | Trigger Condition          | Exit Condition                   | Behavior                          |
|-------------|----------------------------|----------------------------------|-----------------------------------|
| **OFF**     | <65°C (60+5)               | Temp ≥ 65°C                      | Fan disabled                      |
| **TAPER**   | Temp ≤ 60°C from ACTIVE    | Temp ≥ 67°C or timer elapsed     | Minimum speed for configured mins |
| **ACTIVE**  | 65°C - 85°C                | Temp ≤ 60°C or Temp ≥ 85°C       | Quadratic speed response          |
| **EMERGENCY**| ≥85°C                     | Temp ≤ 80°C (with hysteresis)    | Immediate full speed (255 PWM)    |
| **MANUAL** (MQTT only) | Auto Mode switched OFF in Home Assistant | Auto Mode switched back ON | Fan speed fully controlled by the Manual PWM slider; the temperature-based state machine above is bypassed entirely (see [Manual Mode Behavior](#manual-mode-behavior)) |

### State Transitions
- **OFF → ACTIVE**: Temperature rises above activation threshold (65°C)
- **ACTIVE → TAPER**: Temperature drops below minimum threshold (60°C)
- **ACTIVE → EMERGENCY**: Temperature reaches critical level (85°C)
- **TAPER → OFF**: Cool-down period (default: 90 minutes) completes
- **TAPER → ACTIVE**: Temperature rises significantly above activation threshold (67°C, with 2°C buffer)
- **EMERGENCY → ACTIVE**: Temperature drops significantly below critical level (80°C, with 5°C hysteresis)
- **(any state) → MANUAL**: Auto Mode switched OFF via MQTT/Home Assistant (MQTT integration only);
  the auto state machine's current state is frozen/bypassed while manual
- **MANUAL → OFF**: Auto Mode switched back ON via MQTT/Home Assistant; the state machine
  resyncs from a clean OFF state (fans re-evaluated from scratch, same as cold start)

## Monitoring & Logging
Key operational signals:
```log
# Temperature Monitoring
TEMP: RAW=68℃ | SMOOTH=65℃ | DELTA=-3℃

# Speed Calculations
CALC: temp_diff=5℃ | range=20℃ | speed=100pwm

# State Transitions
STATE: OFF→ACTIVE (67℃ ≥ 65℃)
STATE: ACTIVE→TAPER (59℃ ≤ 60℃)
STATE: →EMERGENCY (86℃ ≥ 85℃)
STATE: EMERGENCY→ACTIVE (79℃ ≤ 80℃)
STATE: TAPER→ACTIVE (67℃ ≥ 67℃)

# Speed Changes
SET: 55→80pwm | Reason: Ramp-up limited: 55→80pwm
SET: 120→255pwm | Reason: EMERGENCY: Temp 86℃ ≥ 85℃

# Enhanced Learning System
LEARNING: 80→85pwm (+5 (rising temp 2℃)) [Rate=7]
LEARNING: 95→90pwm (-5 (stable below threshold)) [Rate=5]
LEARNING: 100→99pwm (-1 (efficiency optimization)) [Rate=5]

# Error Handling
ERROR: Failed to read temperature (attempt 1)
ALERT: Multiple temperature read failures - using last known temperature
SAFETY: Activating emergency mode due to sensor failure

# Configuration Validation
CONFIG: Invalid MIN_TEMP value: 25 (should be between 30 and 80), using default: 60
CONFIG: Updating configuration file with corrected values

# Configuration Management
CONFIG: Missing parameter detected: CHECK_INTERVAL
CONFIG: Updating configuration file with 1 missing parameters
CONFIG: Configuration file updated successfully

# System Status
STATUS: State=ACTIVE | PWM=120 | Temp=72℃
STATUS: State=EMERGENCY | PWM=255 | Temp=86℃
```

View logs with:
```bash
journalctl -u fan-control.service -f          # Live monitoring
journalctl -u fan-control.service --since "10 minutes ago"  # Recent history
```

## Technical Implementation
- **Quadratic Response Curve**:

<br>

$$
PWM = MIN_{PWM} + \frac{(temp_{diff}^2 \times (MAX_{PWM} - MIN_{PWM}))}{temp_{range}^2}
$$

Where:
`temp_diff = current_temp - activation_temp`
`temp_range = MAX_TEMP - activation_temp`


- **Exponential Smoothing**:

<br>

$$
smoothed_{temp} = \frac{\alpha \times previous_{smooth} + (100 - \alpha) \times raw_{temp}}{100}
$$

(α configured via ALPHA parameter)

<br>


- **Enhanced Adaptive Learning**:
  - Adjusts optimal PWM based on thermal performance every 30 minutes (configurable)
  - Uses adaptive learning rate based on temperature stability
  - Implements three learning strategies:
    1. Proactive PWM increase when temperature is rising
    2. PWM reduction when temperature is stable below threshold
    3. Efficiency optimization when running faster than necessary with stable temperatures


- **Robust Error Handling**:
  - Tracks consecutive temperature reading failures
  - Implements safety measures after multiple failures
  - Uses last known temperature when readings fail
  - Activates fans proactively during sensor uncertainty

- **Configuration Validation**:
  - Validates all parameters against reasonable ranges
  - Automatically corrects invalid settings
  - Prevents misconfiguration issues

- **Hardware PWM Limitations**:
  Due to device hardware limitations, the actual PWM values applied may differ from the requested values
  (e.g., setting 50 might result in ~48, or 100 might result in ~92)

## Maintenance
```bash
# Service Management
systemctl status fan-control.service   # Current state
systemctl restart fan-control.service  # Apply config changes

# Full Removal
/data/fan-control/uninstall.sh
```

## MQTT / Home Assistant Integration (Optional)
MQTT support is **entirely optional** and **disabled by default** (`MQTT_ENABLED=false`).
When disabled, `fan-control.sh` behaves exactly like the upstream project: no MQTT calls,
no extra service. Enable it only if you want to monitor and control the fan from Home
Assistant.

MQTT is implemented as a **pure-Bash MQTT client** (`mqtt-lib.sh`, MQTT 3.1.1 over plain
TCP via bash's `/dev/tcp`). This is a deliberate design choice: UniFi OS devices (UDM/UCG/
UXG/UDR/UNVR) have no package manager (no `apt`, no `opkg`), so `mosquitto_pub`/
`mosquitto_sub` cannot normally be installed on them. No external MQTT client binary is
required.

### Requirements
- An MQTT broker reachable from the device (e.g. Mosquitto running on Home Assistant OS
  or elsewhere on your network), listening on a **plaintext** (non-TLS) port. TLS/`mqtts://`
  is not supported.
- Nothing else - `mqtt-lib.sh` is deployed automatically by `install.sh` alongside
  `fan-control.sh`.

### Enabling MQTT
- **During installation**: `install.sh` asks `Enable optional MQTT integration for Home
  Assistant? [y/N]` and, if confirmed, prompts for broker host/port/credentials.
  Non-interactive installs can set `FAN_CONTROL_ENABLE_MQTT=true` (plus
  `FAN_CONTROL_MQTT_HOST`, `FAN_CONTROL_MQTT_PORT`, `FAN_CONTROL_MQTT_USER`,
  `FAN_CONTROL_MQTT_PASSWORD`) as environment variables before running the installer.
- **Later**: edit `/data/fan-control/config` (set `MQTT_ENABLED=true` and the `MQTT_*`
  parameters), then re-run `install.sh` to deploy and start the `mqtt-control.service`
  companion service.

### Architecture
Two independent systemd services are involved:
- **fan-control.service** (always installed): the original control loop, now also
  publishing a retained JSON state message to MQTT every cycle when `MQTT_ENABLED=true`,
  and reading the current mode (`auto`/`manual`) from a shared state file every iteration.
- **mqtt-control.service** (only installed when MQTT is enabled): listens for commands
  from Home Assistant, persists the desired mode/PWM to the shared state file, and
  publishes Home Assistant MQTT Discovery messages at startup. Both services use the
  same `mqtt-lib.sh` pure-Bash MQTT client - no external MQTT client dependency.

### Home Assistant Entities (via MQTT Discovery)
Once enabled, these entities appear automatically in Home Assistant, no manual
configuration required:
- **Fan Control State** (sensor): OFF / TAPER / ACTIVE / EMERGENCY / MANUAL (the latter
  while Auto Mode is off - the auto state machine is bypassed and this is reported instead
  of a stale auto-state name)
- **Fan Control Temperature** (sensor): smoothed temperature (°C)
- **Fan Speed** (sensor): current fan speed as a percentage (0-100%)
- **Fan Control Auto Mode** (switch): ON = automatic control (default), OFF = manual control
- **Fan Control Manual PWM** (number, 0-100%): fan speed slider; greyed out/disabled in
  Home Assistant while Auto Mode is ON, and becomes interactive only when Auto Mode is OFF

### Manual Mode Behavior
Turning off **Auto Mode** hands full control of the fan to the **Manual PWM** slider:
- The value you set is applied directly to every detected fan channel and **persists
  across reboots** (stored in `/data/fan-control/mqtt_mode`).
- **There is no automatic EMERGENCY failsafe override in manual mode.** The fan stays
  exactly at the percentage you set, even if the temperature reaches critical levels.
  This is an intentional design choice to give you full manual control; re-enable Auto
  Mode (or adjust the slider yourself) if you need automatic thermal protection again.
- Switching back to Auto Mode immediately resumes the normal state machine.

### MQTT Topics
```
<MQTT_BASE_TOPIC>/<hostname>/state       # published by fan-control.sh (JSON, retained)
<MQTT_BASE_TOPIC>/<hostname>/mode/set    # subscribed by mqtt-control.sh: "auto" | "manual"
<MQTT_BASE_TOPIC>/<hostname>/pwm/set     # subscribed by mqtt-control.sh: 0-100 (%)
```

## Project Structure
- **fan-control.sh**: The main script that monitors temperature and controls fan speed
  (includes the optional MQTT publishing / manual-mode bypass, active only when
  `MQTT_ENABLED=true`)
- **mqtt-control.sh**: Optional companion script that listens for MQTT commands from
  Home Assistant and publishes MQTT Discovery messages; only installed/run when MQTT is enabled
- **mqtt-lib.sh**: Pure-Bash MQTT 3.1.1 client (CONNECT/PUBLISH/SUBSCRIBE/PINGREQ over
  `/dev/tcp`), shared by fan-control.sh and mqtt-control.sh; always deployed, used only
  when `MQTT_ENABLED=true`
- **install.sh**: Installation script that copies files and sets up the systemd service(s)
  - Supports installation from different branches via the `FAN_CONTROL_BRANCH` environment variable
  - Automatically downloads required files if not found locally
  - Optionally configures and installs the MQTT integration
- **uninstall.sh**: Script to remove the fan control system (and the MQTT integration, if installed)
- **fan-control.service**: Systemd service configuration for the main control loop
- **mqtt-control.service**: Systemd service configuration for the optional MQTT command listener
- **tests/**: Sandboxed test suite (no device, no root required); run with `tests/run-tests.sh`

## Star History

<a href="https://www.star-history.com/?type=date&repos=grausof%2Funifi-fan-control-mqtt">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=grausof/unifi-fan-control-mqtt&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=grausof/unifi-fan-control-mqtt&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=grausof/unifi-fan-control-mqtt&type=date&legend=top-left" />
 </picture>
</a>

## Credits & Acknowledgments
- **Upstream project**: [iceteaSA/unifi-fan-control](https://github.com/iceteaSA/unifi-fan-control) -
  this fork builds on its temperature control logic and adds the optional MQTT/Home Assistant layer
- **Thermal Research**: [UCG-Max Thermal Thread](https://www.reddit.com/r/Ubiquiti/comments/1fr8xyt/)
- **System Integration**: SierraSoftworks service patterns

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/H2H719VB0U)

---

**Disclaimer**: Community project - Not affiliated with Ubiquiti Inc.
**Compatibility**: Verified on UniFi OS 4.0.0+ | UCG-Max, UCG-Fibre, UXG-Fibre, UDM-SE, UDM-Pro-Max, UDR7, UNVR
**License**: MIT
