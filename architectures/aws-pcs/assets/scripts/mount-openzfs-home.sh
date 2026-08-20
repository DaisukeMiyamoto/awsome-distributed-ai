#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# mount-openzfs-home.sh — mount the shared FSx OpenZFS filesystem as /home.
#
# Usage: mount-openzfs-home.sh <fs-id>
#   <fs-id>  FSx OpenZFS filesystem ID (e.g. fs-01234567890abcdef)
#
# On first boot the DLAMI has a local /home already populated (at least
# /home/ubuntu). We rsync it aside, mount the shared FSx OpenZFS export at
# /home, then rsync the aside back in with --ignore-existing so any pre-existing
# shared state wins. IMDS region is used to build the FSx DNS name.
#
# Runs as root. Idempotent — safe to re-run on reboot when the fstab entry is
# already present and /home is already mounted.

set -euo pipefail

FS_ID="${1:?filesystem-id required as $1}"
LOG=/var/log/pcs-mount-openzfs-home.log
exec > >(tee -a "$LOG") 2>&1

# AWS region from IMDSv2 (falls back to metadata-v1 read).
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
if [ -n "$TOKEN" ]; then
  REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)
else
  REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
fi
: "${REGION:?failed to resolve region from IMDS}"

DNS="${FS_ID}.fsx.${REGION}.amazonaws.com"
FSTAB_LINE="${DNS}:/fsx/ /home nfs noatime,nfsvers=3,sync,nconnect=16,rsize=1048576,wsize=1048576,defaults 0 0"

# Already mounted — nothing to do (reboot path).
if mountpoint -q /home; then
  echo "/home already mounted; ensuring fstab entry is present"
  grep -qF "$FSTAB_LINE" /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
  exit 0
fi

# Stash the local /home, mount over it, restore any file that is not on the
# shared filesystem.
mkdir -p /tmp/home
rsync -aA /home/ /tmp/home
grep -qF "$FSTAB_LINE" /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
mount -a -t nfs defaults
if [ "enabled" = "$(sestatus 2>/dev/null | awk '/^SELinux status:/{print $3}')" ]; then
  setsebool -P use_nfs_home_dirs 1
fi
rsync -aA --ignore-existing /tmp/home/ /home
rm -rf /tmp/home

echo "/home mounted from $DNS"
