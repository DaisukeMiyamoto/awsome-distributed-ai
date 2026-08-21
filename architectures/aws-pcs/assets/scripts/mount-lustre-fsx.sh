#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# mount-lustre-fsx.sh — mount the shared FSx for Lustre filesystem at /fsx.
#
# Usage: mount-lustre-fsx.sh <fs-id> <mount-name>
#   <fs-id>       FSx for Lustre filesystem ID (e.g. fs-01234567890abcdef)
#   <mount-name>  MountName as reported by the FSx describe-file-systems API
#                 (a short random-looking string, e.g. "abcdef01")
#
# Runs as root. Idempotent — safe to re-run on reboot when /fsx is already
# mounted.
#
# Callers must gate this script on FSxLustreFilesystemId being non-empty —
# a missing Lustre filesystem is not an error, it is the "no /fsx" opt-out.

set -euo pipefail

FS_ID="${1:?filesystem-id required as $1}"
MOUNT_NAME="${2:?mount-name required as $2}"
LOG=/var/log/pcs-mount-lustre-fsx.log
exec > >(tee -a "$LOG") 2>&1

# -f so a 4xx/5xx body (e.g. a 401 under HttpTokens=required) becomes an empty
# string instead of being passed through as a bogus region; --retry/timeouts to
# ride out a throttled or slow IMDS; || true so a connection failure does not
# kill the script on the assignment line under `set -e` — that would skip the
# ${REGION:?} diagnostic below, and on a TERMINATE action the instance is gone
# before anyone can read the (truncated, error-less) log.
IMDS_CURL="curl -sf --retry 5 --retry-connrefused --connect-timeout 2 --max-time 5"
TOKEN=$($IMDS_CURL -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
if [ -n "$TOKEN" ]; then
  REGION=$($IMDS_CURL -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region || true)
else
  REGION=$($IMDS_CURL http://169.254.169.254/latest/meta-data/placement/region || true)
fi
: "${REGION:?failed to resolve region from IMDS}"

SOURCE="${FS_ID}.fsx.${REGION}.amazonaws.com@tcp:/${MOUNT_NAME}"

mkdir -p /fsx

if mountpoint -q /fsx; then
  echo "/fsx already mounted"
  exit 0
fi

# When the EFA client config service exists (install-fsx-lustre-efa ran on
# first boot), wait for it before mounting so a REBOOT mount doesn't race
# LNet/EFA setup. Ordering only — if the service fails or times out we mount
# anyway and Lustre falls back to TCP (a working slower mount beats no mount;
# same rationale as the HyperPod x-systemd.after= ordering).
# The unit is a oneshot: "activating" while running, then back to "inactive"
# (success) or "failed". Only an in-flight run is worth waiting for — on first
# boot the preceding lifecycle action has already configured LNet inline, and
# a finished unit needs no wait.
EFA_UNIT=configure-efa-fsx-lustre-client.service
if systemctl list-unit-files "$EFA_UNIT" --no-legend 2>/dev/null | grep -q "$EFA_UNIT"; then
  waited=0
  while [ "$(systemctl is-active "$EFA_UNIT" 2>/dev/null)" = "activating" ] && [ "$waited" -lt 180 ]; do
    sleep 5; waited=$((waited+5))
  done
  echo "EFA client config unit: $(systemctl is-active "$EFA_UNIT" 2>/dev/null) after ${waited}s wait (mounting; TCP fallback applies on EFA failure)"
fi

# Bounded retry: the FSx endpoint may not be reachable/resolvable yet on a fresh
# node and `mount` can fail instantly. This action runs with OnError:TERMINATE,
# so a bare failure replaces the node into the same window — retry here so
# TERMINATE fires only on a persistent failure.
n=0; max=6; delay=10
while :; do
  if mount -t lustre -o noatime,flock,lazystatfs "$SOURCE" /fsx && mountpoint -q /fsx; then
    break
  fi
  n=$((n + 1))
  if [ "$n" -ge "$max" ]; then
    echo "ERROR: /fsx mount failed after $max attempts" >&2
    exit 1
  fi
  echo "mount attempt $n/$max failed; retrying in ${delay}s"
  sleep "$delay"
done
# Sticky-world-writable shared root (like /tmp). Don't gate the exit on it: the
# mount already succeeded, and a chmod failure here is shared-side (root_squash /
# read-only fs / MDS), so TERMINATE would just replace-loop. Warn and continue.
chmod 1777 /fsx || echo "WARNING: chmod 1777 /fsx failed though the mount is healthy (shared-side condition); leaving perms, not terminating." >&2
echo "/fsx mounted from $SOURCE"
