# HANDOFF — M5 Pool Wi‑fi (m5ai01 / m5ai02)

**Date:** 2026‑11‑11 · **Status:** RESOLVED & PERSISTENT · **Owner:** martin / opencode session
**Applies to:** both Strix Halo pool boxes (`m5ai01` = 192.168.0.4, `m5ai02` = 192.168.0.64)

---

## 1. Symptom

After the strix‑kernel cutover (boot into `7.3.0-rc5-strix-gpu-bosgame-*`), both boxes came up
**without Wi‑fi**, and no existing tooling could reconnect it:

- `nmcli device connect wlan0` → *"no password file"* / *"Secrets were required, but not provided"*
- `systemctl restart iwd` → device stayed disconnected
- No Wi‑fi IP on either box → boxes unreachable from the desktop (all remote work
  depends on this Wi‑fi; there is no default‑route Ethernet on the pool).

This was the **second consecutive kernel transition** that stranded Wi‑fi, so it had to be
understood, not just poked back up.

## 2. Why it broke (root cause)

**Trigger — interface rename.** The ebuild kernels probe the `mt7925e` (MediaTek Wi‑Fi 7)
driver earlier than the distro kernels (6.18.62 / 7.3.3) did, so the device is named
**`wlan0`** instead of **`wlp195s0`** (systemd predictable name). The saved Wi‑fi profile
was bound to the **interface name**:

```ini
# /etc/NetworkManager/system-connections/wlp195s0-wifi.ini  (as shipped by onboarding)
[connection]
id=wlp195s0-wifi
type=wifi
interface=wlp195s0        # ← name-bound; stops matching when the kernel says wlan0
[wifi]
ssid=TP-Link_EA14
[wifi-security]
psk=<redacted>
key-mgmt=wpa-psk
```

Nothing else changed between the working 6.18/7.3.3 boots and the broken 7.3‑rc5 boots —
the name drift is the entire trigger.

**The chain it had to cross (design, not bug):**

1. The pool's Wi‑fi stack is **NetworkManager → iwd backend**. The distro pins it:
   `/usr/lib/NetworkManager/conf.d/iwd.conf` → `[device] wifi.backend=iwd`.
2. `iwd` is `disabled` as a unit, but **systemd D‑Bus‑activates it**
   (`BusName=net.connman.iwd`) whenever NM starts — so it runs at every boot even though
   `systemctl is-enabled iwd` says `disabled`. (This is the "running but disabled"
   state that confused earlier diagnosis.)
3. This iwd build is **3.12** and boots with **network configuration loading disabled**
   (`iwd[...]: station: Network configuration is disabled.`), so it had **no persisted
   networks** of its own and relied on NM feeding it the PSK per activation.
4. The NM→iwd secret handoff then failed on the renamed-device boots:
   `Network.Connect failed: GDBus.Error:net.connman.iwd.Aborted` +
   `device (wlan0): need-auth (reason 'no-secrets')` + *"No agents were available"*.
   (No agentd session exists for a headless box; with no matching profile/secret
   available to the backend, activation dies.)

So: **name‑drift → no matching profile → iwd backend has no secret → activation fails.**
The iwd native path (its own known‑networks + its own DHCP client) was never broken — it
just had no persisted network to autoconnect to.

## 3. Changes made

| # | Change | Where | Purpose / status |
|---|--------|-------|------------------|
| 1 | Created `/etc/iwd/iwd.conf`: `[General]` `NetworkConfiguration=1` | **both boxes** | iwd now loads persisted known‑networks at startup and **autoconnects at every boot**. This is the fix that makes cold boots self‑sufficient. |
| 2 | iwd known‑network created: `/var/lib/iwd/networks/TP-Link_EA14` (PSK stored by iwd itself) | **both boxes** | The autoconnect target. Created by the one‑time native connect below; iwd manages its content. |
| 3 | One‑time native connect: `iwctl --passphrase <psk> station wlan0 connect TP-Link_EA14` | **both boxes** | Brought Wi‑fi up *immediately* via iwd's native path (association + iwd's internal DHCP client, which assigned 192.168.0.4 / .64). Bypasses the broken NM→iwd secret handoff. |
| 4 | Keyfile de‑named: removed `interface=wlp195s0`, added `macs=3C:EF:A5:06:C9:37` under `[wifi]` | **m5ai01 only** | Makes the NM profile **name‑drift‑proof** (matches by MAC, stable across kernels). Backed up first at `/root/wifi.keyfile.bak` (m5ai01). NM is not what connects today — this is the fallback path, kept correct. |
| 5 | Nothing enabled, nothing removed from the stack | both | iwd stays *D‑Bus‑activated* (its designed boot path). No unit was `systemctl enable`‑d. The distro `iwd.conf` pin (`wifi.backend=iwd`) was left in place. |

### Not done (and why)

- **m5ai02's keyfile was left untouched** — it still carries the stale
  `interface=wlp195s0` binding, but iwd now owns Wi‑fi on both boxes, so the NM keyfile
  is inert on m5ai02. (If we ever go back to NM‑managed Wi‑fi, apply change #4 there too,
  with m5ai02's own `wlan0` MAC.)
- **wpa_supplicant** was *not* installed/configured as the backend — the distro design
  (iwd backend) was preserved; only iwd's persistence was enabled.

### Residue from diagnosis (intentionally kept / noted)

- `m5direct` NM connections on `eno1` (static 10.99.0.2 / 10.99.0.3, desktop = 10.99.0.1):
  a **wired management fallback** — plug a cable desktop→box and you get 10.99.0.x even
  if Wi‑fi fails. Keep.
- `/etc/NetworkManager/conf.d/99-no-iwd.conf` was created during diagnosis (wrong section,
  silently ignored) and **removed** — no residue.
- m5ai01's prod SSH keypair was regenerated (`/home/prod/.ssh/id_ed25519`; the original
  private key had been lost, leaving an orphan `.pub`); m5ai02's
  `/home/prod/.ssh/authorized_keys` was updated to the new pub so the `glm5-swap`
  orchestrator (prod ssh m5ai01→m5ai02 over 192.168.0.64) works again.

## 4. How it works now (steady state)

```
boot → NM starts → D-Bus-activates iwd → iwd reads /etc/iwd/iwd.conf
      (NetworkConfiguration=1) → loads /var/lib/iwd/networks/TP-Link_EA14
      → autoconnect (autoconnect_full/quick) → iwd associates (WPA2‑PSK)
      → iwd's internal DHCP client assigns 192.168.0.x → box reachable
```

Verified on both boxes on 2026‑11‑11:

```
iwd: event: state, old: autoconnect_quick, new: autoconnect_full
iwd: event: connect-info, ssid: TP-Link_EA14, ...
iwd: event: state, old: connecting (auto), new: connected
ip -4: wlan0 UP 192.168.0.4/24   (m5ai01) · 192.168.0.64/24 (m5ai02)
```

## 5. Recovery procedures (if it ever breaks again)

| Failure | Fix |
|---------|-----|
| Box up, no Wi‑fi, iwd running but not connected | `systemctl restart iwd` (re‑reads known‑networks + autoconnects). |
| iwd not running at all | `systemctl start iwd` (temporary; the D‑Bus activation at NM start will bring it at next boot). |
| AP credentials changed | `iwctl --passphrase <new-psk> station wlan0 connect TP-Link_EA14` (iwd re‑persists the new PSK). |
| `wlan0` missing (driver not probed) | `modprobe mt7925e` (module exists in the strix kernels; verify with `ls /lib/modules/$(uname -r)/kernel/drivers/net/wireless/mediatek/`). |
| Box unreachable, console available | The steps above run fine from a serial/USB console; no desktop link needed. |
| Box unreachable, no console | Plug the desktop→box Ethernet cable, activate the `m5direct` connection (`nmcli con up m5direct`), and work over 10.99.0.x. |

## 6. Formalization (for the Ansible repo)

- Ship `/etc/iwd/iwd.conf` (`NetworkConfiguration=1`) + the iwd network config
  (SSID + PSK, from a vault var) in a `system_base` (or `strix_glm`) task, root‑gated.
- Keyfile policy: **MAC‑bound, never name‑bound** (`macs=` under `[wifi]`, no
  `interface=`) — apply to both boxes' `wlp195s0-wifi.ini` for consistency.
- Document the "running but disabled" iwd D‑Bus‑activation semantics in the pool runbook
  (prevents future "why is iwd running?" confusion).
- Note the kernel naming fact: distro kernels → `wlp195s0`; strix ebuild kernels →
  `wlan0`. Anything hardcoding a Wi‑fi interface name is a bug waiting to happen.

## 7. Related (same session, different failure class — cross‑reference)

The Wi‑fi strand was one of two "cold‑boot with cable seated" problems this session. The
other: the **USB4 XDomain link does not train on a cold boot when the cables are already
plugged in** — the stream layer can end up asymmetric (one side's `/dev/tbstream*` at
`in_hopid -1` / unopenable) and needs a re‑seat + `modprobe -r thunderbolt_stream` on
**both** boxes + `setup-usb4stream-lab` re‑run on both. That recovery procedure is being
written up separately in the `strix_glm` runbook.
