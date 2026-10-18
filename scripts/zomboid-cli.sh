#!/usr/bin/env bash
PASSWD=$(cat /home/pzuser/rcon_password)

/usr/local/bin/rcon -a 127.0.0.0:27015 -p "$PASSWD" $@
