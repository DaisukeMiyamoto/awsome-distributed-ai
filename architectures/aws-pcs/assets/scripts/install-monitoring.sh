#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# install-monitoring.sh — install the Prometheus/Grafana monitoring stack on
# the login node. Runs as a PCS node lifecycle action in the nodeReady stage
# (slurmd is already up; the installer does not depend on Slurm, but nodeReady
# keeps the node's registration from waiting on a multi-minute Docker install).
#
# Usage: install-monitoring.sh <monitoring-version> <monitoring-repo> [<dcgm-exporter-image>]
#   monitoring-version   — aws-parallelcluster-monitoring git ref (tag/branch)
#   monitoring-repo      — GitHub "owner/repo" to fetch from
#   dcgm-exporter-image  — optional dcgm-exporter image override; empty keeps
#                          the installer's default pin
#
# stdout/stderr land in the per-script lifecycle log
# (/var/log/amazon/pcs/lifecycle/actions/nodeReady/install-monitoring.log).

set -uo pipefail

MONITORING_VERSION="${1:?monitoring-version required as $1}"
MONITORING_REPO="${2:?monitoring-repo required as $2}"
# The monitoring installer reads DCGM_EXPORTER_IMAGE from its environment and
# falls back to its default pin when empty. See aws-parallelcluster-monitoring #50.
export DCGM_EXPORTER_IMAGE="${3:-}"

echo "Installing monitoring stack: ${MONITORING_REPO}@${MONITORING_VERSION}"

# Fetch post-install.sh from MONITORING_REPO at the MONITORING_VERSION ref and
# pass both to it so the tarball is pulled from the same source — this lets a
# fork + branch be used for testing unreleased changes.
curl -fsSL --retry 3 --retry-delay 15 \
  "https://raw.githubusercontent.com/${MONITORING_REPO}/${MONITORING_VERSION}/post-install.sh" \
  -o /tmp/post-install.sh || {
    echo "ERROR: failed to fetch monitoring post-install.sh from ${MONITORING_REPO}@${MONITORING_VERSION} after 3 attempts"
    exit 1
  }

# Make every child `apt-get` in the upstream installer wait up to 5 min for
# the dpkg lock (default is fail-fast). The installer runs unedited, so we
# can't pass `-o DPkg::Lock::Timeout=300` per-call — an apt.conf.d drop-in
# applies globally to the caller and its children. Guards against races with
# unattended-upgrades / apt-daily at first boot.
echo 'DPkg::Lock::Timeout "300";' > /etc/apt/apt.conf.d/99lock-timeout

# Retry up to 3 times for non-lock transient failures (network flakes, image
# pulls). The installer is idempotent (reuses the existing Grafana SSM param,
# recreates containers), so re-running self-heals a one-off hiccup instead of
# leaving the node unmonitored.
rc=1
for attempt in 1 2 3; do
  echo "Monitoring install attempt ${attempt}/3..."
  bash /tmp/post-install.sh "${MONITORING_VERSION}" "${MONITORING_REPO}"
  rc=$?
  [ "$rc" -eq 0 ] && break
  echo "Monitoring install attempt ${attempt} failed (exit ${rc}); retrying in 15s..."
  sleep 15
done

echo "Monitoring installation complete (exit ${rc})"
exit "$rc"
