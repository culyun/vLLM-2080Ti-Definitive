# NVIDIA Turing operational notes: Xid 119 / GSP firmware

*Internal ops note, 2026-07-25. Records the Xid 119 (GSP RPC timeout) incident
on manapouri after the R=31 rung, what the error means, how to recover, and
the standing workaround. Keep updated if the fault recurs.*

## 1. Incident record (2026-07-25, manapouri)

- **Machine:** manapouri, 3× RTX 2080 Ti (22 GiB), driver **580.173.02**,
  CUDA 13.0, Arch Linux.
- **Symptom:** `nvidia-smi` showed `ERR!` for fan/temp/perf on GPU0
  (03:00.0) and GPU1 (04:00.0); both cards unresponsive with ~6 MiB memory
  used and no processes. GPU2 (81:00.0, driving Xorg) unaffected.
- **Kernel log:** first `Xid 119` at **09:59:46** on GPU0, then repeated
  Xid 119 on GPU0 and GPU1, each a 6-second timeout waiting for
  `GSP_RM_CONTROL` RPC responses. Subsequent `nvidia-smi` invocations
  themselves hung and generated further Xid 119 entries (pid = nvidia-smi).
  Secondary symptom: `NVRM: os_schedule: Attempted to yield the CPU while in
  atomic or interrupt context` spam once the GSP was wedged.
- **Timing vs. compute:** the last manapouri R=31 shards (7–9) completed and
  wrote DONE markers at **09:39:08** — twenty minutes *before* the first
  Xid. The cards hung while **idle**, most plausibly during a P-state /
  power-management transition after the compute load ended. **Shard data
  integrity is therefore not in question** (and the merge's CPU spot-verify
  gate checks it independently regardless).

## 2. What Xid 119 means

Since the R510+ driver series, NVIDIA offloads most of the resource manager
(RM) onto the **GSP — GPU System Processor**, a RISC-V microcontroller on the
die, running signed "GSP-RM" firmware (`gsp_*.bin` shipped with the driver).
The kernel driver then talks to the card via an RPC channel instead of
running the RM logic on the host CPU.

- **Xid 119** = the CPU side waited (6 s) for an RPC reply from GSP-RM and
  got nothing: the **GSP firmware has hung or deadlocked**. The RPC history
  dump in dmesg shows the pending function (here `GSP_RM_CONTROL`).
- Once wedged, the card does not recover on its own. Every subsequent
  driver interaction (including `nvidia-smi`) times out with further
  Xid 119s. Related: **Xid 120** (GSP error response), same subsystem.
- Known pattern on **Turing** cards with 5xx drivers: hangs correlate with
  idle power-state transitions and low-activity periods, not with load.
  This matches our incident exactly (failure 20 min into idle).

Other Xids worth knowing for quick triage (not this incident):
**79** = GPU fell off the bus (PCIe/power, hardware-leaning);
**13/31** = compute fault in a kernel (our bug);
**48** = double-bit ECC error (bad memory; N/A on GeForce).

## 3. Recovery

- **Reboot.** Xid 119 does not clear otherwise. A module reload
  (`modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia`) is usually
  impossible here because Xorg holds GPU2, and it tends to hang against a
  wedged GSP anyway. Full power cycle preferred over warm reboot if the
  cards come back with lingering errors.
- After reboot, confirm health: `nvidia-smi` clean; `dmesg | grep -i xid`
  empty; optionally a shard-tool `--selftest` pass on each GPU.

## 4. Standing workaround: disable GSP offload

The legacy CPU-side RM path (the default for years pre-R510) avoids the GSP
firmware entirely and is the standard fix for recurring Xid 119 on Turing:

- **Kernel cmdline:** `nvidia.NVreg_EnableGpuFirmware=0`
- **Or modprobe.d** (`/etc/modprobe.d/nvidia-gsp.conf`):

  ```
  options nvidia NVreg_EnableGpuFirmware=0
  ```

  On Arch, if the nvidia modules are in the initramfs, regenerate it after
  adding the file: `mkinitcpio -P`.

- **Verify it took** after reboot:
  `nvidia-smi -q | grep -i gsp` → `GSP Firmware Version : N/A`, or
  `grep EnableGpuFirmware /proc/driver/nvidia/params` → `0`.

Caveats:

- Only possible with the **proprietary** kernel modules. The open-source
  kernel modules (`nvidia-open`) *require* GSP — the parameter is ignored /
  unsupported there. (We are on proprietary; keep it that way on this box.)
- Performance impact for our workloads is negligible: GSP offload mainly
  reduces host-CPU overhead for display/virtualization-heavy management
  churn, not CUDA compute throughput. The compute path is unchanged.
- Long-term, NVIDIA is deprecating the non-GSP path in new driver majors;
  if a future driver drops it, the alternative is pinning the last driver
  that supports legacy RM on Turing, or tolerating GSP with the mitigation
  below.

Softer mitigation if staying on GSP: keep persistence mode on
(`nvidia-smi -pm 1`) so the driver never fully tears down / re-inits the
cards between jobs — the teardown/idle transitions are where the hangs
cluster.

### 4a. Status on manapouri (2026-08-27 review)

Checked during the vLLM launcher hardening pass; the box is currently in the
**known-bad configuration** and the workaround has **not yet been applied**:

- Driver **580.178.04** (proprietary kernel module), CUDA 13.0 — same 580
  series as the incident driver 580.173.02. Note this also drifts from the
  vLLM fork's validated stack (`PROJECT_RELEASE.env`: driver 590.48.01,
  CUDA 12.8); re-check GSP behavior if/when the driver moves to 590.
- `nvidia-smi -q` shows `GSP Firmware Version : 580.178.04` (GSP **active**;
  `EnableGpuFirmware: 18` = default-auto) and
  `Persistence Mode : Disabled` (softer mitigation also off).
- Proprietary module confirmed via `/proc/driver/nvidia/version`, so the
  `NVreg_EnableGpuFirmware=0` path **is available**.

To apply (pending host change, needs root + reboot):

```
echo 'options nvidia NVreg_EnableGpuFirmware=0' \
  | sudo tee /etc/modprobe.d/nvidia-gsp.conf
sudo mkinitcpio -P     # nvidia modules are in the initramfs on this box
sudo reboot
```

Then verify: `nvidia-smi -q | grep -i gsp` → `GSP Firmware Version : N/A`,
or `grep EnableGpuFirmware /proc/driver/nvidia/params` → `0`. Record the
driver version the workaround was applied under (non-GSP RM is deprecated in
newer driver majors).

Launcher-side defenses (added 2026-08-27 in `launcher.sh`): all `nvidia-smi`
calls are bounded by `timeout` (a hang is reported as a suspected wedged GSP
instead of hanging the launcher), launches abort if `nvidia-smi` times out,
and the kernel journal is scanned for `NVRM: Xid` lines after startup
smoke / failed starts (startup window) and on service stop (serving window),
matching the §5 hygiene rule. The scan matches `NVRM: Xid` specifically —
a bare `xid` grep false-positives on the r8169 NIC's `XID` chip-ID line.

## 5. Campaign hygiene

- After every rung (or before trusting a READY marker), scan the kernel log:
  `journalctl -k | grep -iE 'xid|nvrm'`. **Compare Xid timestamps against
  the shard DONE-marker times.** Errors after the last DONE (this incident)
  are an ops nuisance only; errors *during* the compute window mean the
  affected shard's data is suspect — re-run it, or at minimum concentrate
  the merge's `--verify` sampling inside that shard's index range.
- The pipeline's existing defenses (DONE markers gated on `next_batch`,
  merge zero-entry completeness check, random + top-5 CPU oracle
  spot-verify, capped-list CPU rescan) mean a wedged GPU produces *missing*
  or *failing* data, not silently wrong data. Keep it that way: any new GPU
  tool should die loudly rather than emit partial output.
