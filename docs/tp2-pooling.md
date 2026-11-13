# Two-box Gufo-TP2 pooling over USB4 RDMA (m5ai01 + m5ai02)

Status: LIVE since 2026-11-10. This document is the operational record of
the pooling experiment: what was built, what it measures, how to run/verify/
roll back, and what the repo now owns.

## 1. Topology

```
 m5ai01 (192.168.0.4)              m5ai02 (192.168.0.64)
 kernel 7.3.3-gentoo-dist          kernel 6.18.62-gentoo-dist-bin
 rank0: HTTP :8000, bootstrap      rank1: worker only (no HTTP)
   18515, control 18516            dials rank0 bootstrap over LAN
      |  USB4 link: 20.0 Gb/s × 2 lanes = 40 G class (flipped-cable       |
       |  orientation; 19.4 Gbit/s usable via native_write_striping)   |
      +---- usb4_rdma5/6 rails (RoCEv2, MTU 4096) ----+
      tbv0 dummy 192.168.240.1            tbv0 dummy 192.168.240.2
```

- Two BOSGAME BeyondMax (Strix Halo / gfx1151) units, 128 GB unified
  memory each, BIOS: UMA frame buffer = 1 GiB, GTT pinned to 117.2 GiB
  (30720000 pages; bumped from 110 GiB on 2026-11-11 for the GLM-5.3
  engine) via `ttm.pages_limit=30720000` (kernel cmdline; see the
  amd_gtt role notes — on m5ai02 the boot loader bypasses
  /etc/modprobe.d, so the cmdline is the source of truth).
- One 1 m "TB5 80G" USB4 cable (superseded the original TB3 eGPU
  cable; the very first 240 W USB2 charging cable *cannot* train a
  USB4 link at all — a plain USB2 cable is electrically silent on
  the routers). Link rate is orientation-dependent: with the m5ai02
  end flipped 180° the link trains 20.0 Gb/s × 2 = 40 G class
  (stable across hot retrains and cold boots); unflipped it settles
  at 10 Gb/s × 2 = 20 G. HAZARD: re-plugging unmarked silently drops
  to 20 G — the m5ai02 end should carry a tape mark so it is always
  re-seated flipped.
- Model: `Qwen3.8-Flash-Next` UD-Q4_K_XL (4-shard GGUF + MTP Q8 draft
  + vision proj, 108 GB on each box at `/home/prod/models/flash-next`),
  served by the gufo-tp2 container image with 2-rank tensor parallel.


### BIOS state (both boxes, 2026-11-11)

Three USB4-related settings, kept in their current values:

- **USB4 pre-CM Enable → Disabled** (CBS > FCH Common Options > USB4
  Configuration Options) — keeps the BIOS Pre-OS Connection Manager
  from initializing the USB4 router before Linux takes over.
- **UCSI Support → Enabled** (Advanced > USB/Thunderbolt
  Configurations) — the OS drives PD/Alt-Mode via ucsi_acpi.
- **Reconfig Rebalance Resources by OS → Enabled** (same section) —
  the OS reallocates PCIe resources on USB4 hot-plug.

Side effect: the back USB4 ports now hot-train on cable plug
(previously cold-boot-only). Link *rate* is NOT set by these
settings — 40 G vs 20 G is the cable orientation (see the cable
bullet above).

Hidden advanced menu (BeyondMax BIOS): Del → **Alt+F5** → save &
exit → reboot → Del again. The Advanced settings (incl. the
CBS/FCH and USB/Thunderbolt sections above) are only visible on
that second entry.

## 2. Measured numbers (2026-11-10)

| Quantity | Value |
|---|---|
| RDMA (gufo single-QP, striped) | `ib_write_bw` **19.4 Gbit/s** on the 40 G link (18.6 at 20 G; 8.9 unstripped — the single-QP RDMA path caps at ~19.5 Gbit/s regardless of link speed) |
| Model load | ~21–23 s per rank (60.5 GiB weights + snapshot cache into 112.64 GiB GTT) |
| Prefill | 149–161 tok/s single-user |
| Decode | **76–77.7 tok/s** single-user with `native_write_striping` (44.5–51.6 without; MTP drafts 73–78 % accepted) |
| Prefix cache | 33.2 GiB snapshot capacity; a repeat prompt is a cache hit (~0.1 s restore vs ~3 s prefill) |
| Context | 512 K × 2 sessions as deployed (`--enable-yarn`); total concurrent ≈ 1.0 M tokens |
| Memory cost | ~62 GiB host RAM per box while loaded (zero when unloaded — ttl auto-unload) |
| Bandwidth headroom | at 33–51 tok/s the pair pushes ~0.4–1.3 Gbit/s sustained; the link runs at <10 % — decode is compute/memory-bound, not cable-bound |

## 3. Repo ownership (what the Ansible tree now owns)

| Piece | Role / location | Gate |
|---|---|---|
| Helper filecaps, `DefaultLimitMEMLOCK`, subuid ranges | `system_base` (C2) | `system_base_managed` (root run) |
| llama-swap `cmd_override` contract + TP2 model entry + `LimitMEMLOCK` unit line | `llama_swap` (C3) | `llama_swap_deploy` |
| Launcher scripts, prod ssh trust, image build/load, model sync | `gufo_tp2` (C4) | `gufo_tp2_managed`; per-run: `gufo_tp2_image_deploy`, `gufo_tp2_model_sync` |
| DKMS module + kernel-adaptive variant, modprobe params, tbv0 dummy | `usb4_rdma` (C5, root play) | `usb4_rdma_managed` (CLI) |

The image build recipe lives in
`ansible/roles/gufo_tp2/files/docker/gufo-tp2.Dockerfile` (the three
fixes baked in: no stray `trusted=yes` apt source, `-DNO_MAN_PAGES=ON`
for the prebuilt pandoc stub, `CMAKE_PREFIX_PATH` pointing at the
base image's `_rocm_sdk_devel` site-packages). The image digest is
pinned in both host_vars (`gufo_tp2_image_digest`).

## 4. Operations

### Routine (prod user, no special invocation)

```bash
ansible-playbook -i ansible/inventory.yaml ansible/playbook.yaml -l m5ai01,m5ai02
```

Deploys the launcher scripts + ssh trust (converges to byte-identical
live files) and renders the llama-swap config/unit (restarts the
service only when the rendered files differ). All root-gated tasks
stay inert without their gate.

### Cutover window (root; after a kernel change, a DKMS variant
switch, or the first onboarding of a box)

```bash
# 1. stop the pair (if live): POST /api/models/unload on :8000,
#    or on each box: podman stop gufo-tp2-rank0 / gufo-tp2-rank1
# 2. the root play:
ansible-playbook -i ansible/inventory.yaml ansible/playbook.yaml \
  -l m5ai01,m5ai02 -e ansible_user=root \
  -e ansible_private_key_file=$HOME/.ssh/keys/root.key \
  -e usb4_rdma_managed=true -e gufo_tp2_managed=false
```

### Transport module swap (gufo <-> GLM on 7.3.4, 2026-11-13)

The gufo RDMA module (`thunderbolt_ibverbs`) and the GLM stream
layer (`thunderbolt_stream`) share the NHI rings — only one can hold
them at a time, on any kernel:

- **GLM resident** (the default): the module is NOT loaded at boot
  (no modules-load.d entry; the DKMS allowlist keeps it out of the
  lab kernels). If it was loaded for a gufo session: `rmmod
  thunderbolt_ibverbs` on both boxes, then fire the GLM catalog
  entry.
- **gufo session**: `modprobe thunderbolt_ibverbs` on both boxes (the
  `.ko` is pre-built by the 40-dkms install chain for 7.3.4), stop
  the GLM pair, then fire a gufo catalog entry.

While the module is loaded, `thunderbolt_stream` stream opens fail
with `ENOMEM` (ring reservation by the module), and vice versa — so
the cutover between the engines always starts with the module swap.

Verified on 7.3.4-gentoo-dist (Experiment B, 2026-11-13): gufo TP2
pair 51.7 tok/s decode (MTP 225/272 accepted), gufo single-rank
57.8 tok/s, GLM pair restored after `rmmod` at 42.7 tok/s with a
95% prefix-cache hit on the 2-turn probe. The RDMA rails register
on modprobe alone (4 `usb4_rdma` devices, tbv0 netdev), no XDomain
service pairing needed for enumeration.

`-e gufo_tp2_managed=false` keeps play 1's prod-owned file deployment
out of the root run (ownership drift guard). The role refuses to run
while TP2 containers are live on the host.

### First-run bootstrap (one-time, out-of-band by design)

The prod ssh keypair is created by the role, but the initial
authorized_keys line on m5ai02 must be placed via the root key (the
role's assert prints the exact command when the probe fails):

```bash
ssh -i ~/.ssh/keys/root.key root@192.168.0.64 \
  "grep -qF '<contents of m5ai01:/home/prod/.ssh/id_ed25519_m5ai02.pub>' \
   /home/prod/.ssh/authorized_keys \
   || echo '<pub>' >> /home/prod/.ssh/authorized_keys"
```

### Post-reboot recovery (runtime-only state)

Everything persists except the RDMA link + the containers:

1. wait ~12 s after rails register (the module autoloads
   parameterized via modules-load.d; verify: `ibv_devices` shows
   usb4_rdma5/6, `ip -4 addr show tbv0` shows the .240.x address)
2. within 30 s of each other: run the pair — the clean path is a
   single llama-swap request for model id
   `gufo-qwen3.8-flash-next-tp2-q4` on `http://192.168.0.4:8000`
   (auto-launches rank1 via ssh + rank0 in foreground, ~22 s to ready)

### Verification one-liners

```bash
# rails + bandwidth
ibv_devices | grep usb4_rdma && ib_write_bw -d usb4_rdma5 -F   # server on one box, -R on the other
# serving state
curl -s http://192.168.0.4:8000/v1/models
# what is loaded where
ssh prod@192.168.0.4 'podman ps --filter name=gufo-tp2'
ssh prod@192.168.0.64 'podman ps --filter name=gufo-tp2'
```

## 5. The four operational gotchas (all discovered live)

1. **memlock chain.** A rootless container can never raise its
   RLIMIT_MEMLOCK hard cap above the *spawning service's* cap
   (userns root lacks init-ns CAP_SYS_RESOURCE), so
   `podman --ulimit memlock=-1:-1` is a silent no-op when the parent
   is capped at 8 MB. The fix is two layers: `DefaultLimitMEMLOCK=infinity`
   in `/etc/systemd/system.conf` (user-manager inheritance) +
   `LimitMEMLOCK=infinity` on the llama-swap user unit. PAM-login
   sessions (ssh, `su -`) were already unlimited — that asymmetry is
   why the manual launch worked before the service path was fixed.
2. **`--net=host` is mandatory.** The default slirp netns traps the
   bootstrap listener (18515) inside the container; rank1's LAN
   connection never arrives → "bootstrap accept timed out".
3. **XDG_RUNTIME_DIR hygiene.** `su prod` from a root session leaks
   `/run/user/0`; podman's C init then probes root's 0700 XDG tree,
   gets EACCES (not in its tolerated errno list) and dies. Use real
   PAM sessions (`su -`, ssh, systemd).
4. **The 30 s window + ~12 s rail registration.** rank0 and rank1
   must start within 30 s of each other, after the rails are
   registered (~12 s post-boot). Swaps race on the bootstrap port
   if the old pair hasn't exited — the wrapper's stop_all waits for
   both gufo processes to be gone.

## 6. The thinking-mode budget lesson (model-side)

The deployed 4-bit model's `thinking: {type: enabled}` reasoning loop
is verbose and did NOT converge at 16 K or 40 K `max_tokens` on a
large review task (pure reasoning, zero content, `finish: length`);
it converged at a 200 K budget (~34 K actual, 17 min). Practical:
thinking-off + ~12 K for fast work; thinking-on only with ≥64 K
budget; verify its factual claims against the boxes (it cannot see
them). Q8 weights are the expected remedy for the verbose loop.

## 7. Rollback

- GRUB: the 6.18.62 entry is retained on m5ai01 (Advanced submenu)
  next to the 7.3.3 default — boot it to roll the kernel back; the
  DKMS variant step re-aligns the module source on next cutover run
  (7.3.3 uses the dev form; 6.18.62 Gentoo uses the pdev form).
- llama-swap restart (if the service is ever stopped by hand):
  `su - prod -c 'llama-swap --config /home/prod/.config/llama-swap/config.yaml --listen 0.0.0.0:8000 &'`
- Image: re-load from the tar on m5ai01
  (`/root/gufo-img/gufo-tp2-gfx1151.tar`) or rebuild via the role's
  image gate after unpinning the digest in host_vars.
- Pair stop: `POST /api/models/unload` or `podman stop` on each box.

## 8. Roadmap (out of scope for this pass)

- rank1 as a systemd user unit on m5ai02 (the current ssh-detached
  `nohup` is debug-adequate; the unit survives box reboots better)
- Q8 weights (~2× the weight footprint; check the 117.2 GiB GTT
  budget before the sync)
- Second cable for the big-model path (GLM-5.3-Flash / DeepSeek
  class). The 1 m "TB5 80G" cable trains the full 40 Gbps (20.0 Gb/s
  × 2) but ONLY in a specific orientation (the m5ai02 end flipped
  180°); unflipped it settles at 20 G. 40 G is confirmed stable
  across cold boots in that orientation. CAUTION: an unmarked
  unplugged/replugged cable silently drops to 20 G — mark the m5ai02
  end (tape) so it is always re-seated flipped. Performance note:
  gufo's single-QP RDMA path caps at ~19.5 Gbit/s regardless of link
  speed (8.9 unstripped → 18.6 @20G → 19.4 @40G striped), so 20 G
  vs 40 G is performance-identical for the current TP2 deployment
  (decode ~77 tok/s either way); the ~37–44 Gbit/s the big models
  want needs TWO cables (4 rails), not a faster link.
- 7.3.3 kernel on m5ai02 (newer USB4/XDomain kernel features; no
  measurable benefit at the current single-cable operating point)
