#!/bin/bash

# Check if an argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <email_address>"
    exit 1
fi

# Get the email address from the positional argument
sender="$1"
subject="$2"
rcpt_to="$3"

[ "$sender" = "gitlab@sko.ai" ]             && echo "Gitlab" && exit
[ "$sender" = "notifications@github.com" ]  && echo "Github" && exit
[ "$sender" = "alertmanager@sko.ai" ]       && echo "Alerts" && exit
