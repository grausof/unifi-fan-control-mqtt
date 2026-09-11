#!/bin/bash
###############################################################################
# UniFi Fan Control - Minimal pure-Bash MQTT client (MQTT 3.1.1, QoS 0 only)
#
# UniFi OS devices (UDM/UCG/UXG/UDR/UNVR) have no package manager (no apt,
# no opkg), so `mosquitto_pub`/`mosquitto_sub` are normally NOT available and
# cannot be installed through a standard package manager. This library
# implements just enough of the MQTT 3.1.1 wire protocol (CONNECT, PUBLISH,
# SUBSCRIBE, PINGREQ/PINGRESP, DISCONNECT) using only bash builtins plus
# `dd`/`od` (both part of coreutils and present on every Linux system,
# including UniFi OS) to read raw bytes off a TCP socket opened through
# bash's `/dev/tcp` pseudo-device. No external MQTT client binary is needed.
#
# This file is meant to be `source`d by fan-control.sh and mqtt-control.sh.
# It requires bash 4+ (uses `read -N`), which is standard on UniFi OS.
#
# Limitations (acceptable for this project's use case):
#   - QoS 0 only (fire-and-forget publish, at-most-once subscribe)
#   - No TLS - plaintext MQTT only (the standard port 1883), no "mqtts://"
#   - No Last Will and Testament
#   - A single connection is used at a time (fixed file descriptor 3)
# Because MQTT_LIB_FD is a single fixed descriptor and all state is
# global, this library is NOT reentrant/concurrency-safe. Do not source and
# use it from two parallel invocations (background jobs, subshells racing
# on the same fd, etc.) within the same process tree.
###############################################################################

# Force the C locale for this library. This is required for correctness, not
# just style: bash's `${#string}` counts *characters*, not bytes, and under a
# UTF-8 locale a multi-byte character (e.g. the "°" in a temperature unit)
# would be counted as 1 instead of 2 bytes. Since the MQTT wire format is
# entirely byte-length-prefixed, that mismatch desyncs the packet framing
# and corrupts every subsequent packet on the same connection. Exported here
# (not `local`) so it also covers string length calculations done by the
# calling script (fan-control.sh / mqtt-control.sh) while building payloads.
export LC_ALL=C

MQTT_LIB_FD=3
MQTT_LIB_CONNECTED=false
# Exported (not just declared) because these globals are read by the
# sourcing script (fan-control.sh / mqtt-control.sh) rather than within this
# file - export tells ShellCheck they are intentionally used externally.
export MQTT_LIB_LAST_ERROR=""
export MQTT_LIB_LAST_PACKET_TYPE=""
export MQTT_LIB_RX_TOPIC=""
export MQTT_LIB_RX_PAYLOAD=""
export MQTT_LIB_RX_RETAIN=0

# Configurable timeout (seconds) applied to every blocking socket
# read after the very first header byte of a packet. Previously only the
# first byte of CONNACK had a timeout (`read -t 5`); every subsequent `dd`
# read had none at all, so a broker that sent a partial packet and then
# went silent would hang the script forever. Override before sourcing this
# file if a different value is needed.
export MQTT_LIB_READ_TIMEOUT="${MQTT_LIB_READ_TIMEOUT:-10}"

# Hard ceiling (bytes) on any single PUBLISH payload this library
# will accept. Fan-control/telemetry payloads are small JSON blobs, so this
# is generous but still bounded - it stops a malicious/misbehaving broker
# from declaring a huge payload and exhausting memory/CPU on embedded
# hardware (UDM etc.). Override before sourcing if larger payloads are
# genuinely expected.
export MQTT_LIB_MAX_PAYLOAD_LEN="${MQTT_LIB_MAX_PAYLOAD_LEN:-65536}"

# Write the raw byte for decimal value $1 (0-255) directly to the socket.
# Bytes are streamed straight to the fd (never stored in a bash variable),
# because bash variables cannot hold embedded NUL bytes - and MQTT length
# prefixes routinely contain 0x00 bytes (e.g. the MSB of any length < 256).
_mqtt_send_byte() {
    local octal
    octal=$(printf '%03o' "$(($1 & 0xFF))")
    printf '%b' "\\${octal}" >&${MQTT_LIB_FD}
}

# Write a 2-byte big-endian length prefix followed by the raw bytes of $1.
_mqtt_send_str() {
    local s="$1"
    local len=${#s}
    _mqtt_send_byte $(((len >> 8) & 0xFF))
    _mqtt_send_byte $((len & 0xFF))
    printf '%s' "$s" >&${MQTT_LIB_FD}
}

# Write the MQTT "remaining length" variable-length encoding for byte count $1.
_mqtt_send_remaining_length() {
    local len=$1 byte
    while true; do
        byte=$((len % 128))
        len=$((len / 128))
        if ((len > 0)); then
            byte=$((byte | 0x80))
        fi
        _mqtt_send_byte "$byte"
        ((len == 0)) && break
    done
}

# Read exactly $1 raw bytes from the socket and print them as space-separated
# decimal values. Safe for embedded NUL bytes (unlike bash `read`, which
# cannot store NUL in a variable) because the bytes are piped straight
# through `od` as text, never captured as raw binary in a bash variable.
#
# The read is wrapped in `timeout` so a broker that stops
# sending mid-packet cannot hang this call forever. On timeout/EOF this
# prints nothing (callers already treat an empty result as failure).
_mqtt_read_bytes_dec() {
    local count=$1
    ((count <= 0)) && return 0
    timeout "$MQTT_LIB_READ_TIMEOUT" dd bs=1 count="$count" <&${MQTT_LIB_FD} 2>/dev/null | od -An -tu1 -v | tr -s ' \n' ' '
}

# Read exactly $1 raw bytes and print them as text. Only safe when the
# caller knows the bytes contain no NUL (true for the UTF-8 topic names and
# JSON payloads used throughout this project).
#
# Wrapped in `timeout` for the same reason as _mqtt_read_bytes_dec.
# A sentinel byte ("X") is appended after the raw read and then
# stripped off afterwards. Without this, `$(...)` command substitution
# silently strips ALL trailing newlines from the captured bytes - so a
# payload legitimately ending in "\n" (e.g. pretty-printed JSON) would be
# silently corrupted with no error raised. Appending a non-newline sentinel
# means any real trailing newlines are no longer at the end of the
# substituted output, so bash leaves them alone; we then remove just the
# sentinel character.
_mqtt_read_bytes_text() {
    local count=$1
    ((count <= 0)) && {
        printf ''
        return 0
    }
    local raw
    raw=$(timeout "$MQTT_LIB_READ_TIMEOUT" dd bs=1 count="$count" <&${MQTT_LIB_FD} 2>/dev/null; printf 'X')
    printf '%s' "${raw%X}"
}

# Read a 2-byte big-endian length field, printing the decoded integer.
_mqtt_read_uint16() {
    local bytes
    local -a b
    bytes=$(_mqtt_read_bytes_dec 2)
    read -ra b <<<"$bytes"
    printf '%d' $(((${b[0]:-0} << 8) | ${b[1]:-0}))
}

# Read the MQTT variable-length "remaining length" field, printing the
# decoded integer. Prints nothing and returns non-zero if the socket closed
# or the encoding is malformed.
#


_mqtt_read_remaining_length() {
    local multiplier=1 value=0 byte_dec iterations=0
    while true; do
        byte_dec=$(_mqtt_read_bytes_dec 1)
        [[ -z "$byte_dec" ]] && return 1
        value=$((value + (byte_dec & 0x7F) * multiplier))
        if (((byte_dec & 0x80) == 0)); then
            break
        fi
        multiplier=$((multiplier * 128))
        # The MQTT 3.1.1 spec caps this field at 4 encoded bytes (max value 68,435,455).
        ((iterations++))
        if ((iterations >= 4)); then
            MQTT_LIB_LAST_ERROR="malformed-remaining-length-too-long"
            return 1
        fi
    done
    printf '%d' "$value"
}

# Close the MQTT socket (if open) without sending a DISCONNECT packet.
_mqtt_close_socket() {
    exec {MQTT_LIB_FD}<&- 2>/dev/null
    exec {MQTT_LIB_FD}>&- 2>/dev/null
    MQTT_LIB_CONNECTED=false
}

# Open a TCP connection to the broker and perform the MQTT CONNECT handshake.
# Usage: mqtt_lib_connect host port client_id [user] [pass] [keepalive_secs]
mqtt_lib_connect() {
    local host="$1" port="$2" client_id="$3" user="${4:-}" pass="${5:-}" keepalive="${6:-30}"

    MQTT_LIB_CONNECTED=false
    MQTT_LIB_LAST_ERROR=""

    if [[ -z "$pass" && -n "${MQTT_LIB_PASS:-}" ]]; then
        pass="$MQTT_LIB_PASS"
    elif [[ "$pass" == @* ]]; then
        local pass_file="${pass#@}"
        if [[ ! -r "$pass_file" ]]; then
            MQTT_LIB_LAST_ERROR="cannot-read-pass-file:${pass_file}"
            return 1
        fi
        IFS= read -r pass <"$pass_file"
    fi

    # `keepalive` feeds directly into `$(( ))` arithmetic contexts
    # below. Bash arithmetic expansion recursively re-expands variable
    # content, including command substitutions - so an unvalidated value
    # from an untrusted source (config file, env var, another process'
    # output) could inject and execute arbitrary commands here. Reject
    # anything that isn't a plain non-negative integer before it is ever
    # used arithmetically, and clamp it to the protocol's 16-bit field.
    if [[ ! "$keepalive" =~ ^[0-9]+$ ]]; then
        MQTT_LIB_LAST_ERROR="invalid-keepalive-value: ${keepalive}"
        return 1
    fi
    ((keepalive > 65535)) && keepalive=65535

    # Bash emits its own "Connection refused"/"Name or service not known"
    # diagnostic for a failed /dev/tcp open directly to fd 2, ignoring a
    # redirection on this same command (a long-standing bash quirk). Save
    # and redirect fd 2 for the duration of the attempt so failures stay
    # silent and are reported through MQTT_LIB_LAST_ERROR instead.
    exec 4>&2 2>/dev/null
    exec 3<>"/dev/tcp/${host}/${port}"
    local tcp_rc=$?
    exec 2>&4 4>&-
    if ((tcp_rc != 0)); then
        MQTT_LIB_LAST_ERROR="tcp-connect-failed: cannot reach ${host}:${port}"
        return 1
    fi

    local connect_flags=2 # bit1 = Clean Session
    [[ -n "$user" ]] && connect_flags=$((connect_flags | 0x80))
    [[ -n "$pass" ]] && connect_flags=$((connect_flags | 0x40))

    local var_header_len=10 # "MQTT" (2+4) + level (1) + flags (1) + keepalive (2)
    local payload_len=$((2 + ${#client_id}))
    [[ -n "$user" ]] && payload_len=$((payload_len + 2 + ${#user}))
    [[ -n "$pass" ]] && payload_len=$((payload_len + 2 + ${#pass}))
    local remaining=$((var_header_len + payload_len))

    _mqtt_send_byte 0x10
    _mqtt_send_remaining_length "$remaining"
    _mqtt_send_str "MQTT"
    _mqtt_send_byte 4
    _mqtt_send_byte "$connect_flags"
    _mqtt_send_byte $(((keepalive >> 8) & 0xFF))
    _mqtt_send_byte $((keepalive & 0xFF))
    _mqtt_send_str "$client_id"
    [[ -n "$user" ]] && _mqtt_send_str "$user"
    [[ -n "$pass" ]] && _mqtt_send_str "$pass"

    # Read CONNACK: fixed header byte must be 0x20, then remaining length
    # (always 2), then session-present flag + return code.
    local header_char header_dec
    if ! read -r -t 5 -N 1 -u ${MQTT_LIB_FD} header_char || [[ -z "$header_char" ]]; then
        MQTT_LIB_LAST_ERROR="no-connack-received"
        _mqtt_close_socket
        return 1
    fi
    header_dec=$(printf '%d' "'$header_char")
    if (((header_dec & 0xF0) != 0x20)); then
        MQTT_LIB_LAST_ERROR="unexpected-packet-type-${header_dec}"
        _mqtt_close_socket
        return 1
    fi

    local ack_remaining ack_bytes return_code
    local -a ack_arr
    ack_remaining=$(_mqtt_read_remaining_length)
    if [[ -z "$ack_remaining" ]]; then
        MQTT_LIB_LAST_ERROR="${MQTT_LIB_LAST_ERROR:-connack-read-failed}"
        _mqtt_close_socket
        return 1
    fi
    ack_bytes=$(_mqtt_read_bytes_dec "$ack_remaining")
    read -ra ack_arr <<<"$ack_bytes"
    return_code="${ack_arr[1]:-1}"
    if [[ "$return_code" != "0" ]]; then
        MQTT_LIB_LAST_ERROR="connack-refused-rc${return_code}"
        _mqtt_close_socket
        return 1
    fi

    MQTT_LIB_CONNECTED=true
    return 0
}

# Publish a message. Usage: mqtt_lib_publish topic payload [retain]
# ("retain" as the 3rd arg sets the MQTT retain flag; QoS 0 always.)
mqtt_lib_publish() {
    local topic="$1" payload="$2" retain_flag="$3"
    [[ "$MQTT_LIB_CONNECTED" == true ]] || return 1

    local type_byte=0x30
    [[ "$retain_flag" == "retain" ]] && type_byte=$((type_byte | 0x01))

    local remaining=$((2 + ${#topic} + ${#payload}))

    _mqtt_send_byte "$type_byte" || {
        MQTT_LIB_CONNECTED=false
        return 1
    }
    _mqtt_send_remaining_length "$remaining"
    _mqtt_send_str "$topic"
    if ! { printf '%s' "$payload" >&${MQTT_LIB_FD}; } 2>/dev/null; then
        MQTT_LIB_CONNECTED=false
        return 1
    fi
    return 0
}

# Subscribe (QoS 0) to one or more topic filters in a single SUBSCRIBE packet.
# Usage: mqtt_lib_subscribe_multi topic1 [topic2 ...]
mqtt_lib_subscribe_multi() {
    local topics=("$@")
    [[ "$MQTT_LIB_CONNECTED" == true ]] || return 1
    ((${#topics[@]} > 0)) || return 1

    local remaining=2 # packet identifier
    local t
    for t in "${topics[@]}"; do
        remaining=$((remaining + 2 + ${#t} + 1))
    done

    _mqtt_send_byte 0x82 # SUBSCRIBE (fixed flags = 0x2 per spec)
    _mqtt_send_remaining_length "$remaining"
    _mqtt_send_byte 0x00 # packet id MSB
    _mqtt_send_byte 0x01 # packet id LSB (=1; fine for a single in-flight SUBSCRIBE)
    for t in "${topics[@]}"; do
        _mqtt_send_str "$t"
        _mqtt_send_byte 0x00 # requested QoS 0
    done

    # Best-effort read/discard of the SUBACK response.
    mqtt_lib_read_packet 5 >/dev/null 2>&1
    return 0
}

# Send a keepalive PINGREQ.
mqtt_lib_ping() {
    [[ "$MQTT_LIB_CONNECTED" == true ]] || return 1
    _mqtt_send_byte 0xC0 || {
        MQTT_LIB_CONNECTED=false
        return 1
    }
    _mqtt_send_byte 0x00 || {
        MQTT_LIB_CONNECTED=false
        return 1
    }
    return 0
}

# Gracefully send DISCONNECT and close the socket.
mqtt_lib_disconnect() {
    if [[ "$MQTT_LIB_CONNECTED" == true ]]; then
        _mqtt_send_byte 0xE0 2>/dev/null
        _mqtt_send_byte 0x00 2>/dev/null
    fi
    _mqtt_close_socket
}

# Read and decode the next incoming MQTT control packet, waiting up to
# $1 seconds (default 10) for it to start arriving.
#
# Sets MQTT_LIB_LAST_PACKET_TYPE to one of:
#   PUBLISH      - MQTT_LIB_RX_TOPIC / MQTT_LIB_RX_PAYLOAD are populated
#   PINGRESP     - keepalive response, no payload
#   OTHER        - a recognized-but-unhandled packet (CONNACK, SUBACK, ...),
#                  already fully consumed from the socket
#   TIMEOUT      - nothing arrived within the wait window (connection is
#                  still considered alive; the caller should retry or ping)
#   DISCONNECTED - the socket was closed by the broker/network, or a
#                  malformed/oversized packet forced a protective disconnect
#
# Returns 0 for PUBLISH/PINGRESP/OTHER/TIMEOUT, 1 for DISCONNECTED.
mqtt_lib_read_packet() {
    local timeout="${1:-10}"
    MQTT_LIB_LAST_PACKET_TYPE=""
    MQTT_LIB_RX_TOPIC=""
    MQTT_LIB_RX_PAYLOAD=""
    MQTT_LIB_RX_RETAIN=0

    local header_char rc
    read -r -t "$timeout" -N 1 -u ${MQTT_LIB_FD} header_char
    rc=$?
    if ((rc > 128)); then
        MQTT_LIB_LAST_PACKET_TYPE="TIMEOUT"
        return 0
    elif ((rc != 0)) || [[ -z "$header_char" ]]; then
        MQTT_LIB_LAST_PACKET_TYPE="DISCONNECTED"
        MQTT_LIB_CONNECTED=false
        return 1
    fi

    local header_dec packet_type flags
    header_dec=$(printf '%d' "'$header_char")
    packet_type=$(((header_dec >> 4) & 0x0F))
    flags=$((header_dec & 0x0F))

    local remaining
    remaining=$(_mqtt_read_remaining_length)
    if [[ -z "$remaining" ]]; then
        MQTT_LIB_LAST_PACKET_TYPE="DISCONNECTED"
        MQTT_LIB_CONNECTED=false
        return 1
    fi

    case "$packet_type" in
        3) # PUBLISH
            local topic_len topic consumed qos payload_len payload
            topic_len=$(_mqtt_read_uint16)

            if ((topic_len < 0)) || ((topic_len > remaining - 2)); then
                MQTT_LIB_LAST_ERROR="malformed-publish-topic-len-${topic_len}-exceeds-remaining-${remaining}"
                MQTT_LIB_LAST_PACKET_TYPE="DISCONNECTED"
                _mqtt_close_socket
                return 1
            fi

            topic=$(_mqtt_read_bytes_text "$topic_len")
            consumed=$((2 + topic_len))
            qos=$(((flags >> 1) & 0x03))
            if ((qos > 0)); then
                _mqtt_read_bytes_dec 2 >/dev/null # discard packet id (QoS0 expected)
                consumed=$((consumed + 2))
            fi
            payload_len=$((remaining - consumed))

            if ((payload_len < 0)) || ((payload_len > MQTT_LIB_MAX_PAYLOAD_LEN)); then
                MQTT_LIB_LAST_ERROR="publish-payload-too-large-${payload_len}"
                MQTT_LIB_LAST_PACKET_TYPE="DISCONNECTED"
                _mqtt_close_socket
                return 1
            fi

            payload=""
            if ((payload_len > 0)); then
                payload=$(_mqtt_read_bytes_text "$payload_len")
            fi
            MQTT_LIB_LAST_PACKET_TYPE="PUBLISH"
            MQTT_LIB_RX_TOPIC="$topic"
            MQTT_LIB_RX_PAYLOAD="$payload"
            MQTT_LIB_RX_RETAIN=$((flags & 0x01))
            ;;
        13) # PINGRESP
            MQTT_LIB_LAST_PACKET_TYPE="PINGRESP"
            ;;
        *)
            # Consume and discard the body of packet types we don't act on
            # (CONNACK, SUBACK, UNSUBACK, etc.) so the stream stays in sync.

            if ((remaining > MQTT_LIB_MAX_PAYLOAD_LEN)); then
                MQTT_LIB_LAST_ERROR="unhandled-packet-too-large-${remaining}"
                MQTT_LIB_LAST_PACKET_TYPE="DISCONNECTED"
                _mqtt_close_socket
                return 1
            fi
            if ((remaining > 0)); then
                timeout "$MQTT_LIB_READ_TIMEOUT" dd bs=1 count="$remaining" <&${MQTT_LIB_FD} >/dev/null 2>&1
            fi
            MQTT_LIB_LAST_PACKET_TYPE="OTHER"
            ;;
    esac
    return 0
}