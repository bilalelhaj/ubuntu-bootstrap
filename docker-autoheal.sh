#!/bin/bash

# * * * * * /bin/bash /home/chef/docker-autoheal.sh

LOGFILE="$HOME/docker-autoheal.log"
UNHEALTHY_CONTAINERS=$(docker ps --filter health=unhealthy --format '{{.Names}}')

if [ -z "$UNHEALTHY_CONTAINERS" ]; then
  echo "$(date) - No unhealthy containers found."
else
  for container in $UNHEALTHY_CONTAINERS; do
    echo "$(date) - Restarting: $container" | tee -a "$LOGFILE"
    docker restart "$container" >> "$LOGFILE" 2>&1
  done
fi
