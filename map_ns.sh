#!/bin/bash

# Usage:
# map_cont_ns <pattern>
#
# This script finds a Docker container with a name that contains
# <pattern>, and links the container's network namespace to
# /var/run/netns/<pattern> so that the namespace is visible
# via the 'ip netns ...' command.

CONTAINER_ID=$(docker ps | grep $1 | grep -v pause | awk '{print $1}')
CONTAINER_NAME=$(docker ps | grep $1 | grep -v pause | awk '{print $NF}')
CONTAINER_PID=$(docker inspect -f '{{.State.Pid}}' $CONTAINER_ID)
echo Found container $CONTAINER_NAME, mapping to $1 for 'ip netns' output
mkdir -p /var/run/netns
ln -sf /proc/$CONTAINER_PID/ns/net "/var/run/netns/$2"
