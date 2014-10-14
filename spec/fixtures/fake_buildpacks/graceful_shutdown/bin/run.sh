#!/usr/bin/env bash

trap log_shutdown TERM

function log_shutdown {
  echo "Trapped TERM signal; not shutting down"
}

echo Parent process: $$

echo "Starting app on port $PORT..."
while true; do echo hi | nc -l $PORT; done &

STARTED=$!
echo "Started app with pid $STARTED"

while true; do sleep 1; done

echo "App closed."
