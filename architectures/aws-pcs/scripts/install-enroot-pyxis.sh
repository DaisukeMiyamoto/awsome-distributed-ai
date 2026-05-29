#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Install Enroot and Pyxis on AWS PCS nodes
# Usage: bash install-enroot-pyxis.sh

set -exo pipefail

echo "Starting Enroot/Pyxis installation for AWS PCS..."

ENROOT_RELEASE=3.5.0
PYXIS_RELEASE=v0.20.0
SLURM_VERSIONS="25.05 25.11"

# Install dependencies
echo "Installing dependencies..."
apt-get update
apt-get install -y jq squashfs-tools parallel fuse-overlayfs pigz squashfuse zstd git build-essential

# Install nvidia-container-toolkit if GPU is detected
if nvidia-smi 2>/dev/null; then
  echo "GPU detected, installing nvidia-container-toolkit..."
  . /etc/os-release
  distribution="${ID}${VERSION_ID}"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y libnvidia-container-tools
fi

# Install Enroot
echo "Installing Enroot ${ENROOT_RELEASE}..."
arch=$(dpkg --print-architecture)
mkdir -p /tmp/enroot
cd /tmp/enroot
curl -fSsL -O "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_RELEASE}/enroot_${ENROOT_RELEASE}-1_${arch}.deb"
curl -fSsL -O "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_RELEASE}/enroot+caps_${ENROOT_RELEASE}-1_${arch}.deb"
apt install -y ./*.deb

# Configure Enroot
ln -sf /usr/share/enroot/hooks.d/50-slurm-pmi.sh /etc/enroot/hooks.d/
ln -sf /usr/share/enroot/hooks.d/50-slurm-pytorch.sh /etc/enroot/hooks.d/

mkdir -p /tmp/enroot /tmp/enroot/data
chmod 1777 /tmp/enroot /tmp/enroot/data

wget -O /tmp/enroot.template.conf https://raw.githubusercontent.com/aws-samples/aws-parallelcluster-post-install-scripts/main/pyxis/enroot.template.conf
ENROOT_CACHE_PATH=/tmp/enroot envsubst < /tmp/enroot.template.conf > /etc/enroot/enroot.conf
chmod 0644 /etc/enroot/enroot.conf

# Install Pyxis for all Slurm versions
echo "Installing Pyxis ${PYXIS_RELEASE}..."
for SLURM_VERSION in ${SLURM_VERSIONS}; do
  echo "Installing Pyxis for Slurm ${SLURM_VERSION}..."
  SLURM_PATH="/opt/aws/pcs/scheduler/slurm-${SLURM_VERSION}"
  SLURM_ETC_PATH="/etc/aws/pcs/scheduler/slurm-${SLURM_VERSION}"

  if [ ! -d "${SLURM_PATH}" ]; then
    echo "Warning: Slurm ${SLURM_VERSION} not found at ${SLURM_PATH}, skipping..."
    continue
  fi

  if [ ! -d /tmp/pyxis ]; then
    git clone --depth 1 --branch "${PYXIS_RELEASE}" https://github.com/NVIDIA/pyxis.git /tmp/pyxis
  fi

  cd /tmp/pyxis
  make clean || true
  CPPFLAGS="-I ${SLURM_PATH}/include/" make
  CPPFLAGS="-I ${SLURM_PATH}/include/" make install

  mkdir -p "${SLURM_ETC_PATH}/plugstack.conf.d"
  ln -sf /usr/local/share/pyxis/pyxis.conf "${SLURM_ETC_PATH}/plugstack.conf.d/pyxis.conf"

  echo "Pyxis installed for Slurm ${SLURM_VERSION}"
done

# Update PATH for slurmd
echo 'PATH=/opt/aws/pcs/scheduler/slurm-25.11/bin:/usr/lib/ccache/bin:/usr/local/bin:/usr/bin:/bin' >> /etc/default/slurmd

# Load GPU kernel modules if GPU detected
if nvidia-smi 2>/dev/null; then
  echo "Loading GPU kernel modules..."
  nvidia-container-cli --load-kmods info || true
fi

echo "Enroot/Pyxis installation complete!"
echo "Installed at: $(date)"
echo ""
echo "Verification:"
enroot version
ls -la /etc/aws/pcs/scheduler/slurm-*/plugstack.conf.d/ 2>/dev/null || echo "Plugstack config check skipped"
