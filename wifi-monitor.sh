#!/bin/sh
# WiFi netplay monitor — logs network, CPU, and driver state every second
# Usage: ./wifi-monitor.sh [peer_ip]
# Output: /tmp/wifi-monitor.log

PEER="${1:-}"
LOG="/tmp/wifi-monitor.log"
INTERVAL=1

echo "=== WiFi Monitor started at $(date) ===" > "$LOG"
echo "Peer: ${PEER:-none}" >> "$LOG"

while true; do
    TS="$(date '+%H:%M:%S')"

    # WiFi link quality and signal
    WIFI_INFO="$(iw dev wlan0 link 2>/dev/null)"
    SIGNAL="$(echo "$WIFI_INFO" | grep 'signal:' | awk '{print $2}')"
    TXRATE="$(echo "$WIFI_INFO" | grep 'tx bitrate:' | awk '{print $3,$4}')"
    RXRATE="$(echo "$WIFI_INFO" | grep 'rx bitrate:' | awk '{print $3,$4}')"

    # WiFi station stats (retries, failures, etc.)
    STATION="$(iw dev wlan0 station dump 2>/dev/null)"
    TX_RETRIES="$(echo "$STATION" | grep 'tx retries:' | awk '{print $3}')"
    TX_FAILED="$(echo "$STATION" | grep 'tx failed:' | awk '{print $3}')"
    RX_BYTES="$(echo "$STATION" | grep 'rx bytes:' | awk '{print $3}')"
    TX_BYTES="$(echo "$STATION" | grep 'tx bytes:' | awk '{print $3}')"
    INACTIVE="$(echo "$STATION" | grep 'inactive time:' | awk '{print $3}')"

    # Ping latency (non-blocking, 1 packet, 200ms timeout)
    if [ -n "$PEER" ]; then
        PING="$(ping -c1 -W1 "$PEER" 2>/dev/null | grep 'time=' | sed 's/.*time=\([^ ]*\).*/\1/')"
        [ -z "$PING" ] && PING="TIMEOUT"
    else
        PING="n/a"
    fi

    # CPU load (1-line)
    CPU="$(cat /proc/loadavg | awk '{print $1,$2,$3}')"

    # CPU freq
    FREQ="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)"
    GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"

    # Network interface errors
    NET_STATS="$(cat /proc/net/dev | grep wlan0)"
    RX_ERRS="$(echo "$NET_STATS" | awk '{print $4}')"
    RX_DROP="$(echo "$NET_STATS" | awk '{print $5}')"
    TX_ERRS="$(echo "$NET_STATS" | awk '{print $12}')"
    TX_DROP="$(echo "$NET_STATS" | awk '{print $13}')"

    # IRQ counts for WiFi
    WIFI_IRQ="$(grep -i 'xradio\|sdio\|mmc1\|wlan' /proc/interrupts 2>/dev/null | awk '{sum+=$2}END{print sum}')"

    # Connman service state
    CONNMAN_STATE="$(connmanctl services 2>/dev/null | head -3 | tr '\n' ' ')"

    # Kernel messages (WiFi-related, last 2 seconds)
    DMESG="$(dmesg -T 2>/dev/null | tail -5 | grep -i 'xradio\|wlan\|wifi\|bss\|disassoc\|deauth\|scan' | tail -2)"

    # Log it
    printf "[%s] sig=%sdBm ping=%sms cpu=%s freq=%s/%s tx_ret=%s tx_fail=%s rx_err=%s tx_err=%s rx_drop=%s tx_drop=%s inactive=%sms irq=%s\n" \
        "$TS" "$SIGNAL" "$PING" "$CPU" "$FREQ" "$GOV" \
        "$TX_RETRIES" "$TX_FAILED" "$RX_ERRS" "$TX_ERRS" "$RX_DROP" "$TX_DROP" \
        "$INACTIVE" "$WIFI_IRQ" >> "$LOG"

    [ -n "$DMESG" ] && echo "  DMESG: $DMESG" >> "$LOG"

    sleep "$INTERVAL"
done
