#!/bin/bash

CHANNEL="6"
INTERFACE=$(batocera-wifi get_interface)

SSID=$(batocera-settings-get wifi.adhoc.ssid)
PASSPHRASE=$(batocera-settings-get wifi.adhoc.key)
PASSPHRASE=${PASSPHRASE:-12345678}

adhoc_flag="/tmp/.adhoc_ap_enabled"

hostapd_pid="/tmp/hostapd.pid"
hostapd_conf="/tmp/hostapd.conf"

dnsmasq_pid="/tmp/dnsmasq.pid"
dnsmasq_leases="/tmp/dnsmasq.leases"

should_start_ap() {
    # Check flag file first (written by ES before launch animation)
    # Fall back to settings check
    if [ ! -f /tmp/.netplay_hotspot_requested ]; then
        if [ "$(batocera-settings-get global.netplay)" != "1" ] || [ "$(batocera-settings-get global.netplay.hotspot)" != "1" ]; then
            return 1
        fi
    fi

    if [ -z "$INTERFACE" ]; then
        return 1
    fi

    return 0
}

case $1 in
    gameStart)
        # Performance tuning for all netplay participants (AP and client)
        if [ "$(batocera-settings-get global.netplay)" = "1" ]; then
            cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor > /tmp/.pre_netplay_governor 2>/dev/null
            for policy in /sys/devices/system/cpu/cpufreq/policy*; do
                echo "performance" > "$policy/scaling_governor" 2>/dev/null
            done
            touch /tmp/.netplay_tuned
        fi

        if should_start_ap; then
            # If the AP was already set up by ES (setup_hotspot), skip
            if [ -f "$adhoc_flag" ] && iw dev "$INTERFACE" info 2>/dev/null | grep -q "type AP"; then
                iw dev "$INTERFACE" set power_save off 2>/dev/null
            else
            touch "$adhoc_flag"

            # Kill connman — both connmanctl disconnect and the init stop script
            # can hang. We need the interface free for hostapd anyway.
            # connman will be restarted by gameStop (batocera-wifi enable).
            killall connmand 2>/dev/null
            sleep 0.3
            rm -rf /var/lib/connman/wifi_* 2>/dev/null

            ip link set "$INTERFACE" up
            ip addr flush dev "$INTERFACE"
            sleep 0.1
            ip addr add 192.168.4.1/24 dev "$INTERFACE"

            cat <<EOF > "$hostapd_conf"
interface=$INTERFACE
driver=nl80211
ssid=$SSID
channel=$CHANNEL
hw_mode=g
auth_algs=1
wpa=2
wpa_passphrase=$PASSPHRASE
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wmm_enabled=1
beacon_int=50
preamble=1
EOF

            hostapd "$hostapd_conf" > /tmp/hostapd.log 2>&1 &
            echo $! > "$hostapd_pid"

            dnsmasq --interface="$INTERFACE" \
                    --bind-interfaces \
                    --dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,12h \
                    --dhcp-leasefile="$dnsmasq_leases" \
                    --pid-file="$dnsmasq_pid" \
                    --no-resolv 2>/dev/null

            for i in {1..100}; do
                if iw dev "$INTERFACE" info | grep -q "type AP"; then
                    break
                fi
                sleep 0.1
            done

            # Disable WiFi power save (AP side)
            iw dev "$INTERFACE" set power_save off 2>/dev/null
            fi
        elif [ -n "$INTERFACE" ]; then
            # Client side — disable power save on the connected interface
            iw dev "$INTERFACE" set power_save off 2>/dev/null
        fi
        ;;
    gameStop)
        # Clean up netplay tuning markers
        # Governor is restored by powermode_launch_hooks.sh (runs before us)
        rm -f /tmp/.netplay_tuned /tmp/.pre_netplay_governor

        if [ -f "$adhoc_flag" ]; then
            # Kill hostapd
            if [ -f "$hostapd_pid" ]; then
                kill "$(cat "$hostapd_pid")" 2>/dev/null
                rm -f "$hostapd_pid"
            fi
            killall hostapd 2>/dev/null

            # Kill dnsmasq (uses --pid-file so the PID file is accurate,
            # but killall as fallback in case of stale PID)
            if [ -f "$dnsmasq_pid" ]; then
                kill "$(cat "$dnsmasq_pid")" 2>/dev/null
                rm -f "$dnsmasq_pid"
            fi
            killall dnsmasq 2>/dev/null
            rm -f "$dnsmasq_leases"

            # Reset interface from AP back to managed (station) mode
            ip addr flush dev "$INTERFACE"
            ip link set "$INTERFACE" down
            iw dev "$INTERFACE" set type managed 2>/dev/null
            ip link set "$INTERFACE" up

            rm -f "$adhoc_flag"
            rm -f /tmp/.netplay_hotspot_requested

            # Reset hotspot flag so next game doesn't start AP again
            batocera-settings-set global.netplay.hotspot 0

            # Restore WiFi — disable then enable (same as UI toggle)
            setsid sh -c 'batocera-wifi disable; sleep 1; batocera-wifi enable' &
        elif [ -f /tmp/.netplay_client_wifi_restore ]; then
            # Client was connected to a netplay hotspot — restore previous WiFi
            setsid sh -c 'batocera-wifi restore' &
        fi
        ;;
esac

