# Storage Tests (Test 10)

Validates FSx for Lustre + OpenZFS health, mount options, and performance
regression/improvement testing.

---

## Test 10: FSx storage health

Validates that both shared filesystems (Lustre on `/fsx`, OpenZFS on `/home`)
mount cleanly on every node, are usable, and that the FSx-side configuration
matches what the template asked for. Most of this is exercised implicitly by
Tests 1–9 (the Enroot/Pyxis install, monitoring stack, OSU / FSDP all touch
`/fsx`); this test is the explicit health check to run after a fresh deploy
or after touching `ml-cluster-prerequisites.yaml` / FSx-related parameters.

### Step 1 — both filesystems mounted on every node

On the login node and at least one compute node (via `srun`):

```bash
mount | grep -E ' /home | /fsx '
df -h /home /fsx
```

Expected:
- `/fsx` mounted as type `lustre`, source `<fs-id>.fsx.<region>.amazonaws.com@tcp:/<mountname>`,
  size matches the `Capacity` parameter (1200 GiB default; 19200 GiB or larger
  when `FSxLustreEnableEfa=true`).
- `/home` mounted as type `nfs` over OpenZFS, NFS options include
  `nconnect=16,rsize=1048576,wsize=1048576` (the `mount-openzfs-home.sh`
  lifecycle-action mount string).
- Both `df -h` reports show `Avail` greater than zero.

If a mount is missing on a freshly booted node, check the per-script
lifecycle logs `/var/log/amazon/pcs/lifecycle/actions/nodeBootstrapped/mount-openzfs-home.log`
and `mount-lustre-fsx.log` (root-readable). A mount failure TERMINATES and
replaces the node, so also check the CNG's recent instance churn. The most
common first-boot failure is the OpenZFS DNS name not being resolvable yet
(NFS settle race); the mount log will show `mount.nfs: Failed to resolve server`.

### Step 2 — read/write sanity

```bash
# /fsx (Lustre): write 1 GiB, read it back
dd if=/dev/zero of=/fsx/.healthcheck bs=1M count=1024 conv=fsync 2>&1 | tail -1
dd if=/fsx/.healthcheck of=/dev/null bs=1M 2>&1 | tail -1
rm /fsx/.healthcheck

# /home (OpenZFS / NFS): same, 100 MiB (it's a small home filesystem)
dd if=/dev/zero of=/home/ubuntu/.healthcheck bs=1M count=100 conv=fsync 2>&1 | tail -1
dd if=/home/ubuntu/.healthcheck of=/dev/null bs=1M 2>&1 | tail -1
rm /home/ubuntu/.healthcheck
```

Expected: both write+read complete without error. Throughput is bounded by the
single-stream limits of NFS / Lustre on a single node — this is a sanity check,
not a benchmark. For Lustre throughput numbers, see the FSx Lustre User Guide
(provisioned throughput = `Capacity * PerUnitStorageThroughput / 1024` MB/s).

### Step 3 — FSx-side parameters match the CFN inputs

```bash
FSX_ID=$(aws cloudformation describe-stacks \
  --stack-name <your-stack> \
  --query 'Stacks[0].Outputs[?OutputKey==`FSxLustreFilesystemId`].OutputValue' \
  --region <region> --output text)

aws fsx describe-file-systems --file-system-ids "$FSX_ID" --region <region> \
  --query 'FileSystems[0].[StorageCapacity,StorageType,LustreConfiguration.[DeploymentType,PerUnitStorageThroughput,DataCompressionType,EfaEnabled,MetadataConfiguration.Mode]]' \
  --output text
```

Expected (default deploy):
- `StorageCapacity` = your `Capacity` parameter (1200 by default)
- `StorageType` = `SSD`
- `DeploymentType` = `PERSISTENT_2` (default; or `PERSISTENT_1` if you set it)
- `PerUnitStorageThroughput` = 250 (default)
- `DataCompressionType` = `LZ4` (default)
- `EfaEnabled` = `False` (default; `True` when `FSxLustreEnableEfa=true`. EFA on
  FSx is a PERSISTENT_2-only feature — the prerequisites and deploy-all templates
  enforce this with a CFN Rule that fails the stack at create time when
  `FSxLustreEnableEfa=true` is combined with `LustreDeploymentType=PERSISTENT_1`)
- `MetadataConfiguration.Mode` = `AUTOMATIC` on PERSISTENT_2

For the OpenZFS `/home` filesystem:

```bash
FSXO_ID=$(aws cloudformation describe-stacks \
  --stack-name <your-stack> \
  --query 'Stacks[0].Outputs[?OutputKey==`FSxOFilesystemId`].OutputValue' \
  --region <region> --output text)

aws fsx describe-file-systems --file-system-ids "$FSXO_ID" --region <region> \
  --query 'FileSystems[0].[StorageCapacity,OpenZFSConfiguration.[DeploymentType,ThroughputCapacity]]' \
  --output text
```

### Step 4 — Storage dashboard in Grafana

The `Compute Node Details` and `HPC Cluster Monitoring → Storage` Grafana
dashboards are populated by the **CloudWatch Exporter** (FSx CloudWatch
metrics, scraped by the monitoring stack on the login node — see the
[aws-parallelcluster-monitoring v2.6 release notes](https://github.com/aws-samples/aws-parallelcluster-monitoring/releases/tag/v2.6)).

Open Grafana (Test 1's port-forward / public CIDR), go to the Storage
dashboard, and verify the `/fsx` panels (Throughput, IOPS, Free Capacity,
Client Connections) populate within ~5 minutes of a workload starting. CW
metrics have a ~5 min publishing delay, so a brand-new filesystem with no I/O
shows blank panels for a while; the `dd` from Step 2 is enough to seed values.

### `FSxLustreEnableEfa=true` specifics

When `FSxLustreEnableEfa=true` is set on a PERSISTENT_2 SSD filesystem, the
extra checks beyond the above are:

- `aws fsx describe-file-systems` `LustreConfiguration.EfaEnabled = true`
- `Capacity` is at-or-above the EFA minimum for the chosen
  `PerUnitStorageThroughput` tier (19200 GiB for tier 250; the FSx for
  Lustre User Guide has the full matrix). Below the minimum, the FSx side
  rejects the `CreateFileSystem` with `Invalid storage capacity provided:
  N GiB. Minimum storage capacity for an EFA enabled LUSTRE file systems
  with deployment type PERSISTENT_2, per unit storage throughput X and
  storage type SSD is M`. The Lustre nested stack fails first, then the
  whole stack rolls back; that's the expected behavior for an undersized
  Capacity.

The FSx-side EFA endpoints are usable from EFA-capable clients (CPU CNGs
deployed with `OnDemandEfaInterfaceCount > 0`, P5/P6 GPU CNGs). Plain Lustre client
mounts continue to work over TCP for non-EFA nodes; EFA support is additive.

### Performance regression criteria

For changes that touch mount options or FSx parameters, re-run the throughput
benchmark documented in
[OPERATIONS.md §4.1](../docs/OPERATIONS.md#41-lustre-mount-options--noatime)
(the `noatime` benchmark) and compare against the recorded baseline.
**A >10% degradation blocks the change.**

---

## Test 10b: FSx Lustre over EFA — client verification + benchmark

Validates that `OnDemandEnableFSxLustreEfaClient` / `PseriesEnableFSxLustreEfaClient`
actually put the EFA transport (and GDS on GPU nodes) in the Lustre data path —
not just that the config script ran. Requires a cluster deployed with
`FSxLustreEnableEfa=true` (+ `Capacity` at the EFA minimum for the throughput
tier) and the client toggle on the CNG under test.

> **Interpreting throughput numbers.** The filesystem's aggregate throughput
> cap is `Capacity × PerUnitStorageThroughput` (e.g. 19200 GiB × 250 MB/s/TiB
> ≈ 4.8 GB/s). At the tier-250 minimum, both transports can approach the cap —
> the EFA advantage grows with the tier (it targets single-client rates beyond
> ~10 GB/s at tiers 500/1000). Always report the cap next to the numbers.

Verification is layered — run all four on a node of the EFA-enabled CNG:

### Layer 1 — configuration (lifecycle action ran, LNet has EFA NIDs)

```bash
sudo tail -5 /var/log/amazon/pcs/lifecycle/actions/nodeBootstrapped/install-fsx-lustre-efa.log
# "done"; on GPU nodes the log shows "--optimized-for-gds"
sudo lnetctl net show | grep -c "@efa"
# counts the LOCAL efa NIs (net show lists only local interfaces):
# p6-b200 = 8, p6-b300 = 16, p5/p5e/p5en = 8, 2-card CPU HPC = 2, single-card = 1
systemctl status configure-efa-fsx-lustre-client.service --no-pager | head -3
# loaded + enabled (re-applies the config on reboot)
```

### Layer 2 — peer discovery + selection policy

`lctl get_param osc.*.import` shows `current_connection: ...@tcp` **even when
EFA is carrying the data** — that field is the peer's primary NID label, and
FSx servers identify by their tcp NID. Multi-rail picks the transport per
message, so check instead that (a) LNet discovered the server's efa NID and
(b) the udsp policy prefers efa:

```bash
sudo lnetctl peer show | grep -B1 "@efa"
#     - primary nid: 10.x.x.x@tcp
#         - nid: x.x.x.x@efa        <- the FSx server advertises an efa NID
sudo lnetctl udsp show
#     - src: efa / priority: 0      <- installed by setup.sh (prefer efa)
```

A missing `@efa` peer NID means discovery fell back (wrong AZ, non-EFA
filesystem, or the EFA config ran after the mount). The verdict on whether
EFA actually carries the data comes from Layer 3.

### Layer 3 — traffic attribution (bytes actually flow over EFA)

```bash
sudo lnetctl stats > /tmp/lnet-before
dd if=/dev/zero of=/fsx/efa-probe bs=1M count=8192 oflag=direct
sudo sync; echo 3 | sudo tee /proc/sys/vm/drop_caches
dd if=/fsx/efa-probe of=/dev/null bs=1M iflag=direct
sudo lnetctl stats > /tmp/lnet-after
diff /tmp/lnet-before /tmp/lnet-after   # send/recv byte counters grow by ~16 GiB
rm -f /fsx/efa-probe
```

For per-net attribution, `sudo lnetctl net show -v` before/after shows the
counters on the `efa` net growing while `tcp` stays ~flat.

### Layer 4 — benchmark A/B (EFA vs TCP on the same node + filesystem)

Install the tools once (Ubuntu 24.04 repos):

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y \
  fio openmpi-bin libopenmpi-dev make gcc
```

> Ubuntu 24.04 has no `ior` package — build it (`mdtest` comes with it):
> `curl -fsSLO https://github.com/hpc/ior/releases/download/4.0.0/ior-4.0.0.tar.gz
> && tar xzf ior-4.0.0.tar.gz && cd ior-4.0.0 && ./configure && make -j && sudo make install`
> (needs `libopenmpi-dev make gcc`). Use **ior for writes and fio (direct=1)
> for reads**: ior's same-node write-then-read hits the client page cache, and
> its `--posix.odirect` read aborts on Lustre (verified rc=255).

**B = EFA (as deployed):**

```bash
mkdir -p /fsx/iorbench && cd /fsx/iorbench
mpirun -np 16 --oversubscribe ior -w -t 1m -b 2g -F -e -g -o /fsx/iorbench/ior.dat
fio --name=seqw --directory=/fsx/iorbench --rw=write --bs=1M --size=4G \
    --numjobs=8 --direct=1 --group_reporting --unlink=1
fio --name=seqr --directory=/fsx/iorbench --rw=read  --bs=1M --size=4G \
    --numjobs=8 --direct=1 --group_reporting
```

**A = TCP (remove the efa NIs from LNet; traffic falls back to TCP — no reboot):**

```bash
for dev in $(ls /sys/class/infiniband/); do sudo lnetctl net del --net efa --if "$dev"; done
sudo lnetctl net show | grep -c "@efa"        # 0
echo 3 | sudo tee /proc/sys/vm/drop_caches
# rerun the same ior + fio commands (new -o path for ior)
```

Re-adding EFA: `sudo systemctl restart configure-efa-fsx-lustre-client.service`
(verified to restore all NIs). Record both runs side by side with the
filesystem cap; **EFA must be >= TCP on both write and read**.

Reference numbers — p6-b200.48xlarge, 19200 GiB PERSISTENT_2 @ tier 250
(nominal aggregate ~4.8 GB/s), single client, 2026-08-21:

| Benchmark | EFA | TCP | ratio |
|---|---|---|---|
| ior write (16 ranks, file-per-proc) | 4740 MiB/s | 591 MiB/s | **8.0×** |
| fio write (8 jobs, 1M, direct) | 5477 MB/s | 620 MB/s | **8.8×** |
| fio read (8 jobs, 1M, direct) | 7754 MB/s | 620 MB/s | **12.5×** |
| mdtest create (8 ranks, mean of 3) | 11752 ops/s | 12103 ops/s | ~parity |
| mdtest stat (8 ranks, mean of 3) | 16291 ops/s | 13353 ops/s | +22%¹ |
| mdtest removal (8 ranks, mean of 3) | 12578 ops/s | 12121 ops/s | ~parity |

¹ stat is latency-bound pure-RPC traffic (metadata RPCs ride LNet too), so a
modest EFA advantage is plausible — but the run-to-run stddev (~10%) overlaps;
treat metadata as "no regression, possible small win", not an EFA headline.

The TCP path bottlenecks on the single ksocklnd connection over the primary
ENA (~5 Gbps); EFA spreads across all efa NIs and reaches (and bursts past)
the filesystem's nominal cap.

### GDS (GPU nodes, optional)

With `--optimized-for-gds` configured, compare GDS vs POSIX reads using the
CUDA-bundled gdsio (path varies by CUDA version):

```bash
GDSIO=$(ls /usr/local/cuda*/gds/tools/gdsio | head -1)
sudo $GDSIO -f /fsx/iorbench/gds.dat -d 0 -w 8 -s 8G -i 1M -x 0 -I 1   # write
sudo $GDSIO -f /fsx/iorbench/gds.dat -d 0 -w 8 -s 8G -i 1M -x 0 -I 0   # GDS read
sudo $GDSIO -f /fsx/iorbench/gds.dat -d 0 -w 8 -s 8G -i 1M -x 2 -I 0   # CPU-bounce read (comparison)
```

`-x 0` is the GPUDirect path; `-x 2` bounces through CPU memory. GDS read at
or above the CPU-bounce rate confirms the nvidia-fs/cuFile path is active.
Reference (same setup as above): GPUD write 6.34 GiB/s, GPUD read 5.75 GiB/s,
CPU-bounce read 5.67 GiB/s — parity at this filesystem tier; the GDS latency
advantage grows with the throughput tier.
