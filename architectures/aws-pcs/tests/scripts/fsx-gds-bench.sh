#!/bin/bash
# fsx-gds-bench.sh — GPUDirect Storage (GDS) read/write benchmark for FSx for
# Lustre, run on a GPU node. Companion to ./fsx-bench-suite.sh (POSIX/metadata);
# this one exercises the cuFile path, which is where the EFA client + §4.2
# tuning pays off the most for ML data loading.
#
# Usage: sudo ./fsx-gds-bench.sh <label> [mount-point]
#   label        tag for this run (e.g. "efa-tier250-tuned")
#   mount-point  Lustre mount to benchmark (default /fsx)
#
# For each transfer size (1 MiB, 16 MiB) it measures, with a page-cache drop
# before every read:
#   - GPUD write   (-x 0 -I 1): host->GPU->storage, GPUDirect path
#   - GPUD read    (-x 0 -I 0): storage->GPU, GPUDirect path
#   - bounce read  (-x 2 -I 0): storage->CPU->GPU, the cuFile compat-mode path
# The GPUD-vs-bounce read delta quantifies what the direct DMA path buys over
# bouncing through CPU memory. `-x 0` is GPUDirect; `-x 2` bounces via CPU.
#
# cuFile config: the DLAMI runs cuFile fine with NO /etc/cufile.json (built-in
# defaults). An empty or invalid file breaks the driver ("cuFile driver open
# error: 5001" / "-22"); the GDS reference repo's cufile.json
# (allow_compat_mode: false) also fails to open on the DLAMI. If you need a
# config file, start from the CUDA template (/usr/local/cuda-*/gds/cufile.json).
#
# Results append to <mount>/bench-results/<label>.txt and print to stdout.
# Run as root (drop_caches).
set -uo pipefail
LABEL="${1:?label required}"
MNT="${2:-/fsx}"
OUT="$MNT/bench-results"; mkdir -p "$OUT" && chmod 1777 "$OUT"
R="$OUT/$LABEL.txt"
say(){ echo "[$LABEL] $*" | tee -a "$R"; }
dropc(){ sync; echo 3 > /proc/sys/vm/drop_caches; }

GDSIO=$(ls /usr/local/cuda*/gds/tools/gdsio 2>/dev/null | head -1)
if [ -z "$GDSIO" ] || ! nvidia-smi >/dev/null 2>&1; then
  say "gdsio or GPU not available — this script must run on a GPU node with the CUDA GDS tools"
  exit 1
fi

BDIR="$MNT/gds-$LABEL"; mkdir -p "$BDIR"
say "=== GDS ENV ==="
say "date: $(date -u +%FT%TZ)  host: $(hostname)  gdsio: $GDSIO"

for IOS in 1M 16M; do
  DAT="$BDIR/gds-$IOS.dat"
  say "=== gdsio $IOS GPUD write (-x 0 -I 1) ==="
  "$GDSIO" -f "$DAT" -d 0 -w 8 -s 4G -i "$IOS" -x 0 -I 1 2>&1 | tail -1 | tee -a "$R"
  say "=== gdsio $IOS GPUD read (-x 0 -I 0) ==="
  dropc
  "$GDSIO" -f "$DAT" -d 0 -w 8 -s 4G -i "$IOS" -x 0 -I 0 2>&1 | tail -1 | tee -a "$R"
  say "=== gdsio $IOS CPU-bounce read (-x 2 -I 0) ==="
  dropc
  "$GDSIO" -f "$DAT" -d 0 -w 8 -s 4G -i "$IOS" -x 2 -I 0 2>&1 | tail -1 | tee -a "$R"
  rm -f "$DAT"
done

say "=== DONE $LABEL ==="
