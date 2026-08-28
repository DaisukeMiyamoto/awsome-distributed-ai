#!/bin/bash
# fsx-bench-suite.sh — reproducible single-client FSx for Lustre benchmark
# (POSIX + metadata transport comparison).
#
# Usage: sudo ./fsx-bench-suite.sh <label> [mount-point]
#   label        tag for this run (e.g. "efa-tier250", "tcp-baseline")
#   mount-point  Lustre mount to benchmark (default /fsx)
#
# Measures, in a fixed order with page-cache drops between phases:
#   - ior sequential write, 16 MPI ranks, file-per-process, 1 MiB and 16 MiB
#     transfers (writes only: ior's same-node write-then-read hits the client
#     page cache, and --posix.odirect reads abort on Lustre)
#   - fio sequential write + cold read, 8 jobs, direct=1, 1 MiB and 16 MiB
#   - mdtest, 8 ranks x 1000 files x 3 iterations (metadata create/stat/remove)
#   - LNet per-net send counters before/after, so every byte is attributable
#     to a transport (efa vs tcp) — the decisive check that EFA is in the
#     data path (Lustre's osc import shows the peer's tcp NID either way)
#
# GPUDirect Storage (gdsio) is measured separately by ./fsx-gds-bench.sh — it
# needs a GPU node and exercises a different (cuFile) path.
#
# Results append to <mount>/bench-results/<label>.txt and print to stdout.
#
# Prerequisites (Ubuntu 24.04 has no ior package — build it; mdtest ships
# with ior):
#   sudo apt-get install -y fio openmpi-bin libopenmpi-dev make gcc
#   curl -fsSLO https://github.com/hpc/ior/releases/download/4.0.0/ior-4.0.0.tar.gz
#   tar xzf ior-4.0.0.tar.gz && cd ior-4.0.0 && ./configure && make -j && sudo make install
#
# Run as root (drop_caches); mpirun runs as $SUDO_USER when set.
set -uo pipefail
LABEL="${1:?label required}"
MNT="${2:-/fsx}"
RUNAS="${SUDO_USER:-ubuntu}"
OUT="$MNT/bench-results"; mkdir -p "$OUT" && chmod 1777 "$OUT"
R="$OUT/$LABEL.txt"
say(){ echo "[$LABEL] $*" | tee -a "$R"; }
lnet_counts(){ lnetctl net show -v 2>/dev/null | python3 -c "import sys,re; t=sys.stdin.read(); print({n.split()[0]: sum(int(x) for x in re.findall(r'send_count: (\d+)', n)) for n in re.split(r'- net type: ', t)[1:]})"; }
dropc(){ sync; echo 3 > /proc/sys/vm/drop_caches; }

say "=== ENV ==="
say "date: $(date -u +%FT%TZ)  host: $(hostname)"
say "efa NIs: $(lnetctl net show 2>/dev/null | grep -c '@efa' || echo 0)"
say "OSTs: $(lfs df "$MNT" 2>/dev/null | grep -c OST)"
say "lnet before: $(lnet_counts)"

BDIR="$MNT/bench-$LABEL"; mkdir -p "$BDIR" && chown "$RUNAS:$RUNAS" "$BDIR"

for BS in 1m 16m; do
  say "=== ior write $BS (16 ranks fpp) ==="
  dropc
  su - "$RUNAS" -c "cd $BDIR && mpirun -np 16 --oversubscribe /usr/local/bin/ior -w -t $BS -b 2g -F -e -g -o $BDIR/ior-$BS.dat" 2>&1 | grep -E "^write" | head -1 | tee -a "$R"
  say "=== fio write $BS (8 jobs, direct) ==="
  fio --name=w$BS --directory="$BDIR" --rw=write --bs=${BS^^} --size=4G --numjobs=8 --direct=1 --group_reporting --unlink=0 2>/dev/null | grep "WRITE:" | tee -a "$R"
  say "=== fio read $BS (8 jobs, direct, cold) ==="
  dropc
  fio --name=w$BS --directory="$BDIR" --rw=read --bs=${BS^^} --size=4G --numjobs=8 --direct=1 --group_reporting 2>/dev/null | grep "READ:" | tee -a "$R"
  rm -f "$BDIR"/w$BS*
done

say "=== mdtest (8 ranks, n=1000, i=3) ==="
su - "$RUNAS" -c "mkdir -p $BDIR/mdt && mpirun -np 8 --oversubscribe /usr/local/bin/mdtest -n 1000 -d $BDIR/mdt -u -i 3" 2>&1 | grep -E "File creation|File stat|File removal" | tee -a "$R"

say "lnet after: $(lnet_counts)"
say "=== DONE $LABEL ==="
