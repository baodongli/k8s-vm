#!/bin/bash

# Usage:
# unmap_cont_ns <namespace>
#
# This script removes the link from /var/run/netns for a
# docker container namespace. To find a namespace to use
# for this command, use 'ip netns'.

rm -f /var/run/netns/$1
