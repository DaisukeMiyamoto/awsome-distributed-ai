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

mount -t lustre -o noatime,flock,lazystatfs "$SOURCE" /fsx
chmod 1777 /fsx
echo "/fsx mounted from $SOURCE"
