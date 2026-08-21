#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# install-fsx-lustre-efa.sh — configure LNet over EFA for the FSx for Lustre
# client, enabling the EFA transport (and GPUDirect Storage on GPU nodes).
#
# Runs as the install-fsx-lustre-efa node lifecycle action (nodeBootstrapped
# stage), BEFORE mount-lustre-fsx, when EnableFSxLustreEfaClient=true. The
# filesystem itself must have been created with EfaEnabled
# (FSxLustreEnableEfa=true on the prerequisites stack) and sit in the SAME AZ
# as the node — EFA does not cross AZs; the mount falls back to TCP otherwise.
#
# What it does (per the FSx for Lustre User Guide "Configuring EFA clients"):
#   1. Skips cleanly when the node has no EFA device (fi_info probe), so the
#      toggle is safe on CNGs whose instance type has no EFA.
#   2. Downloads AWS's configure-efa-fsx-lustre-client sample and runs
#      setup.sh (with --optimized-for-gds when a GPU is present — the DLAMI
#      pre-installs the Lustre client, EFA driver and GDS driver, so the
#      separate install step from the guide is not needed).
#   3. setup.sh loads the Lustre/EFA LNet modules, configures the EFA
#      interfaces (count derived from the instance type), and installs a
#      systemd unit (configure-efa-fsx-lustre-client.service) that re-applies
#      the config on reboot — hence FIRST_BOOT_ONLY.
#   4. Installs an IMDS-readiness drop-in for that unit BEFORE running
#      setup.sh: the shipped oneshot unit queries IMDS with no retry and can
#      race network bring-up on reboot (upstream fix, PR #1204).
#
# OnError is CONTINUE by design: if EFA configuration fails, the subsequent
# mount-lustre-fsx still mounts over TCP — a working (slower) filesystem beats
# a replace loop.

set -uo pipefail

LOG_PREFIX="[fsx-lustre-efa]"
log() { echo "${LOG_PREFIX} $*"; }

# --- Guard: EFA device present? -------------------------------------------
if [ ! -x /opt/amazon/efa/bin/fi_info ] || ! /opt/amazon/efa/bin/fi_info -p efa >/dev/null 2>&1; then
  log "no EFA device/provider on this instance type — skipping (mount will use TCP)"
  exit 0
fi
log "EFA provider detected"

# --- GDS only makes sense with a GPU --------------------------------------
GDS_FLAG=""
if nvidia-smi >/dev/null 2>&1; then
  GDS_FLAG="--optimized-for-gds"
  log "GPU detected — configuring with ${GDS_FLAG}"
else
  log "no GPU — configuring EFA transport without GDS"
fi

# --- Fetch AWS's configuration sample (retry; no apt needed) ---------------
WORK=/tmp/configure-efa-fsx-lustre-client-dl
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"
if ! curl -fsSL --retry 3 --retry-delay 15 -O \
    https://docs.aws.amazon.com/fsx/latest/LustreGuide/samples/configure-efa-fsx-lustre-client.zip; then
  log "ERROR: failed to download configure-efa-fsx-lustre-client.zip after 3 attempts"
  exit 1
fi
# python3 zipfile avoids an apt-get for unzip at first boot (dpkg-lock race).
python3 -m zipfile -e configure-efa-fsx-lustre-client.zip .
chmod +x configure-efa-fsx-lustre-client/setup.sh

# --- Harden the systemd unit setup.sh is about to install (IMDS race) ------
# The unit is a oneshot with no Restart= that queries IMDS at boot;
# network-online.target does not guarantee IMDS answers yet. Same fix the
# HyperPod lifecycle script carries (upstream PR #1204).
IMDS_WAIT=/usr/local/sbin/wait-for-ec2-imds
cat > "$IMDS_WAIT" <<'EOF'
#!/usr/bin/env bash
set -u
readonly imds="http://169.254.169.254/latest"
readonly deadline=$((SECONDS + 120))
while ((SECONDS < deadline)); do
  token="$(curl -fsS --connect-timeout 2 --max-time 3 -X PUT \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" "${imds}/api/token" 2>/dev/null)"
  if [ -n "$token" ] && curl -fsS --connect-timeout 2 --max-time 3 \
      -H "X-aws-ec2-metadata-token: $token" "${imds}/meta-data/instance-type" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done
echo "EC2 instance metadata did not become ready within 2 minutes" >&2
exit 1
EOF
chmod 0755 "$IMDS_WAIT"
DROPIN=/etc/systemd/system/configure-efa-fsx-lustre-client.service.d
mkdir -p "$DROPIN"
cat > "$DROPIN/network-readiness.conf" <<EOF
[Unit]
After=cloud-init.service
StartLimitIntervalSec=600
StartLimitBurst=20

[Service]
ExecStartPre=$IMDS_WAIT
Restart=on-failure
RestartSec=10s
EOF
systemctl daemon-reload

# --- Run the AWS setup script ----------------------------------------------
log "running setup.sh ${GDS_FLAG}"
if ! ./configure-efa-fsx-lustre-client/setup.sh ${GDS_FLAG}; then
  log "ERROR: setup.sh failed — the Lustre mount will fall back to TCP"
  exit 1
fi

# --- Report what LNet ended up with ----------------------------------------
EFA_NIDS=$(lnetctl net show 2>/dev/null | grep -c "net type: efa" || true)
log "LNet configured; efa net entries: ${EFA_NIDS}"
lnetctl net show 2>/dev/null | sed "s/^/${LOG_PREFIX} /" | head -40
rm -rf "$WORK"
log "done"
