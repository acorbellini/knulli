#!/bin/bash

case $1 in
    gameStop)
        [ -f /tmp/.netplay_client_wifi_restore ] && batocera-wifi restore &
        ;;
esac
