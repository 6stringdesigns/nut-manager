#!/bin/bash

# Consts
UPS_NAME="nutdev1"                        # NUT UPS identifier (name@host)
BATTERY_WAIT_TIME=60                      # Seconds on battery before shutdown
POWER_RESTORE_WAIT=600                    # Seconds (10min) power must be stable
MIN_BATTERY_LEVEL=90                      # Minimum battery % before wake
CHECK_INTERVAL=5                          # Seconds between status checks
LOG_FILE="/var/log/nut_manager.log"
STATE_FILE="/var/run/nut_manager.state"

# Clients
# hostname:ip:mac_address
CLIENTS=(
    "c-1:192.168.1.1:00:00:00:00:00:00"
    "c-2:192.168.1.2:00:00:00:00:00:00"
)

# SSH settings
SSH_USER="root"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"

# Logger
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Get stats
get_ups_status() {
    upsc "$UPS_NAME" ups.status 2>/dev/null
}

get_battery_charge() {
    upsc "$UPS_NAME" battery.charge 2>/dev/null
}

is_on_battery() {
    local status=$(get_ups_status)
    [[ "$status" =~ OB ]]  # OB = On Battery
}

is_online() {
    local status=$(get_ups_status)
    [[ "$status" =~ OL ]]  # OL = Online
}

# Client functinos
shutdown_client() {
    local hostname=$1
    local ip=$2

    log "Starting shutdown for $hostname ($ip)"

    if ssh $SSH_OPTS "$SSH_USER@$ip" "shutdown -h now" 2>/dev/null; then
        log "Shutdown command sent to $hostname"
        return 0
    else
        log "WARNING: Failed to send shutdown command to $hostname"
        return 1
    fi
}

shutdown_all_clients() {
    log "Shutting down client machines..."

    for client in "${CLIENTS[@]}"; do
        IFS=':' read -r hostname ip user mac <<< "$client"
        shutdown_client "$hostname" "$ip" &
    done

    wait

    log "Waiting 5min for clients to complete shutdown..."
    sleep 300
}

# Send magic packet for wake up
send_wol() {
    local mac=$1
    local hostname=$2

    log "Sending Wake-on-LAN to $hostname ($mac)"

    if command -v etherwake &>/dev/null; then
        etherwake "$mac" 2>/dev/null
    else
        log "ERROR: etherwake not found"
        return 1
    fi
}

wake_all_clients() {
    log "Waking up all client machines..."

    for client in "${CLIENTS[@]}"; do
        IFS=':' read -r hostname ip mac <<< "$client"
        send_wol "$mac" "$hostname"
        sleep 1
    done
}

# States
save_state() {
    local state=$1
    echo "$state:$(date +%s)" > "$STATE_FILE"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "NORMAL:$(date +%s)"
    fi
}

get_state_name() {
    load_state | cut -d: -f1
}

get_state_time() {
    load_state | cut -d: -f2
}

# Main
main_loop() {
    local battery_start_time=0
    local power_restore_time=0
    local clients_shutdown=false

    log "UPS monitoring started for $UPS_NAME"
    log "Configured clients: ${#CLIENTS[@]}"

    while true; do
        local current_state=$(get_state_name)

        # Ping UPS
        if ! upsc "$UPS_NAME" >/dev/null 2>&1; then
            log "ERROR: Cannot communicate with UPS $UPS_NAME"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Set states
        case "$current_state" in
            NORMAL)
                if is_on_battery; then
                    battery_start_time=$(date +%s)
                    clients_shutdown=false
                    save_state "ON_BATTERY"
                    log "ALERT: Power failure detected - UPS on battery"
                fi
                ;;

            ON_BATTERY)
                local elapsed=$(($(date +%s) - battery_start_time))

                if is_online; then
                    log "Power restored before shutdown threshold"
                    save_state "NORMAL"
                    battery_start_time=0
                elif [[ $elapsed -ge $BATTERY_WAIT_TIME ]] && [[ "$clients_shutdown" == "false" ]]; then
                    log "Battery threshold reached ($BATTERY_WAIT_TIME seconds)"
                    shutdown_all_clients
                    clients_shutdown=true
                    save_state "CLIENTS_DOWN"
                fi

                local battery_level=$(get_battery_charge)
                ;;

            CLIENTS_DOWN)
                if is_online; then
                    power_restore_time=$(date +%s)
                    save_state "POWER_RESTORED"
                    log "Power restored - monitoring stability..."
                else
                    # Wait for battery to reach 40% before shutting down UPS
                    local battery_level=$(get_battery_charge)
                    if [[ ${battery_level%.*} -le 40 ]]; then
                        log "Battery at or below 40%, shutting down UPS"
                        upsdrvctl shutdown
                        exit 0
                    else
                        log "Waiting for battery to reach 50% (current: ${battery_level}%)"
                    fi
                fi
                ;;

            POWER_RESTORED)
                local stable_time=$(($(date +%s) - power_restore_time))
                local battery_level=$(get_battery_charge)

                if ! is_online; then
                    log "Power lost again - continue to monitor"
                    save_state "CLIENTS_DOWN"
                    power_restore_time=0
                elif [[ $stable_time -ge $POWER_RESTORE_WAIT ]]; then
                    if [[ ${battery_level%.*} -ge $MIN_BATTERY_LEVEL ]]; then
                        log "Power stable for ${POWER_RESTORE_WAIT}s, battery at ${battery_level}%"
                        wake_all_clients
                        save_state "NORMAL"
                        clients_shutdown=false

                        log "Systems returning to NORMAL state"
                    else
                        log "Battery charge ${battery_level}% below threshold ${MIN_BATTERY_LEVEL}%"
                    fi
                fi
                ;;
        esac

        sleep "$CHECK_INTERVAL"
    done
}

# Startup checks and initialization
startup_checks() {
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root"
        exit 1
    fi

    # Check for required commands
    local missing_cmds=()
    for cmd in upsc ssh; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    # Check for WOL tools
    if ! command -v etherwake &>/dev/null; then
        missing_cmds+=("etherwake")
    fi

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        echo "ERROR: Missing required commands: ${missing_cmds[*]}"
        exit 1
    fi

    # Test UPS connectivity
    if ! upsc "$UPS_NAME" >/dev/null 2>&1; then
        echo "ERROR: Cannot connect to UPS $UPS_NAME"
        echo "Check NUT configuration and ensure upsd is running"
        exit 1
    fi

    # Create log file if it doesn't exist
    touch "$LOG_FILE" 2>/dev/null || {
        echo "ERROR: Cannot create log file $LOG_FILE"
        exit 1
    }

    log "Startup checks passed"
}

# Signal handlers for graceful shutdown
cleanup() {
    log "Received termination signal - shutting down"
    rm -f "$STATE_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Entry point
startup_checks
main_loop
