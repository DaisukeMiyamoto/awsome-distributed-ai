# AWS PCS — Roadmap / TODO

Implementation items under consideration for future work on the AWS PCS templates
(`architectures/aws-pcs`). This is a living checklist — check items off or remove them
when done, and add new ones via PR so the history is captured in git.

Priority: 🔴 high · 🟡 medium · 🟢 low

## Templates & deployment

- [ ] 🟡 **Re-validate P6-B300 NCCL at scale.** The 2-node / 16 GiB `all_reduce` peaked
  at ~760 GB/s busbw, but B300 has 2× the EFA cards of B200 (16 vs 8) and only reached
  ~1.16× the bandwidth — a 2-node run likely doesn't saturate all 16 cards. Re-test with
  **larger messages (up to ~64 GiB) and more nodes (4–8+)**, and confirm NCCL
  topology/rail settings, before treating ~760 GB/s as B300's peak. See
  [tests/README](../tests/README.md) and the GPU validation report.
- [ ] 🟢 **Support targeted ODCR.** Today `CapacityReservationId` forces
  `MarketType=capacity-block`. Add a mode that uses a `CapacityReservationTarget` without
  `capacity-block` so a *targeted* On-Demand Capacity Reservation can be consumed
  explicitly (the current "open ODCR + empty param" path only covers open reservations).
- [ ] 🟢 **Trn (Trainium) node group template.** Only P5/P6 GPU multi-NIC templates exist;
  consider a Trainium equivalent if there's demand.
- [ ] 🟢 **Multi-AZ FSx option.** `OpenZFSDeploymentType` currently excludes `MULTI_AZ`
  because the prerequisites template provisions a single private subnet. Adding a second
  private subnet would enable MULTI_AZ for higher availability.

## Containers / Enroot-Pyxis

- [ ] 🟢 **Pre-bake P6 into the custom AMI recipe.** `pcs-ready-dlami-with-enroot-pyxis.yaml`
  is validated for the first-boot path; confirm/extend the `BuildAMI=true` recipe for the
  P6 families so frequent-scaling users get fast boot there too.

## Monitoring (aws-parallelcluster-monitoring)

- [ ] 🟢 **Surface GPU throttle health correctly.** The misleading throttle summary tiles
  were dropped (upstream #49). A correct signal could be added later using
  `DCGM_FI_DEV_CLOCK_THROTTLE_REASONS` (HW-fault bitmask) instead of the monotonic
  violation counters — requires adding that field to `dcgm/counters.csv`.

## Testing / docs

- [ ] 🟡 **Automate the validation matrix.** The `tests/` guide is run manually; consider a
  script that deploys, runs the CPU/GPU/NCCL/FSDP checks, and asserts the expected results
  for CI-style regression testing.

---

_Completed items are tracked in git history and the validation reports; this file lists
only work still under consideration._
