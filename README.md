# Ubuntu 26.04 multi-user xRDP — granny-clear guide

Turn a fresh Ubuntu Server 26.04 VM into a multi-user XFCE remote desktop
reachable over the plain internet with any RDP client.

> No Cloudflare. No Apache. No SSH tunnel. Just `mstsc.exe` → public IP.
> Verified on Ubuntu 26.04 LTS.

---

## What you get

- XFCE desktop for each Linux user
- Sessions survive disconnect (close lid, reopen laptop, reconnect — same windows)
- Many users in parallel (capped by RAM)
- Non-default port + fail2ban + UFW so you're not a sitting duck on port 3389

---

## Prerequisites

- Fresh Ubuntu Server **26.04 LTS**, fully booted, sudo access
- Public IP, port 22 (SSH) open in the cloud-provider firewall
- ≥ 2 GB RAM per concurrent RDP user (plan accordingly)
- ≥ 4 GB free disk

You'll pick **one** non-default RDP port for the whole guide. Throughout below it
is referred to as `RDP_PORT`. Example: `33890`. Use anything in `10000–65000`
that isn't already taken by something else on the box.

```bash
export RDP_PORT=33890   # remember this — used in xrdp, UFW, fail2ban, client
```

> Keep the same shell window for the whole guide so `$RDP_PORT` stays set,
> or just paste the number literally into each command.

---

## Step 1 — Update the system

```bash
sudo apt update && sudo apt upgrade -y
```

Reboot if the kernel was upgraded:

```bash
sudo reboot   # then ssh back in
```

---

## Step 2 — Install XFCE + xRDP

```bash
sudo apt install -y \
  xfce4 \
  xfce4-goodies \
  xrdp \
  xorgxrdp \
  dbus-x11 \
  xubuntu-wallpapers
```

| Package | Why |
|---|---|
| `xfce4` + `xfce4-goodies` | The desktop itself + extras |
| `xrdp` | The RDP server |
| `xorgxrdp` | Xorg backend — faster than the fallback Xvnc |
| `dbus-x11` | XFCE needs it to start |
| `xubuntu-wallpapers` | Nicer default background (optional) |

> **Do NOT install a display manager** (`gdm3`, `lightdm`, `sddm`). xRDP has
> its own session manager. Adding one causes login loops and wasted RAM.

---

## Step 3 — Let xRDP read its TLS cert

```bash
sudo adduser xrdp ssl-cert
```

Without this xRDP can't read `/etc/ssl/private/ssl-cert-snakeoil.key` and
clients see "connection closed" right after the login screen.

---

## Step 4 — Move xRDP off the default port

Edit `/etc/xrdp/xrdp.ini`:

```bash
sudo sed -i "s|^port=.*|port=tcp://0.0.0.0:${RDP_PORT}|" /etc/xrdp/xrdp.ini
```

Check it landed:

```bash
grep '^port=' /etc/xrdp/xrdp.ini
# expected: port=tcp://0.0.0.0:33890
```

> This won't stop a determined attacker but it cuts 99 % of dumb
> internet-wide port-3389 scans out of your logs.

---

## Step 5 — Tune `sesman.ini` for persistent multi-user sessions

Edit `/etc/xrdp/sesman.ini`:

```bash
sudo sed -i 's/^MaxSessions=.*/MaxSessions=50/'              /etc/xrdp/sesman.ini
sudo sed -i 's/^KillDisconnected=.*/KillDisconnected=false/' /etc/xrdp/sesman.ini
sudo sed -i 's/^DisconnectedTimeLimit=.*/DisconnectedTimeLimit=0/' /etc/xrdp/sesman.ini
sudo sed -i 's/^IdleTimeLimit=.*/IdleTimeLimit=0/'           /etc/xrdp/sesman.ini
```

What the knobs do:

| Setting | Value | Effect |
|---|---|---|
| `MaxSessions` | `50` | Hard cap on concurrent sessions (lower it if RAM is tight: roughly `RAM_GB / 2`) |
| `KillDisconnected` | `false` | Session survives client disconnect |
| `DisconnectedTimeLimit` | `0` | Never auto-kill a disconnected session |
| `IdleTimeLimit` | `0` | Never disconnect an idle session |

---

## Step 6 — Create your first RDP user

```bash
USERNAME=alice    # change me

sudo adduser "$USERNAME"           # interactive, sets password
sudo usermod -aG sudo "$USERNAME"  # optional — only if alice needs sudo
sudo usermod -aG ssl-cert "$USERNAME"
```

Drop an XFCE-session file in their home so the login lands in XFCE and not
a black screen:

```bash
sudo -u "$USERNAME" tee /home/$USERNAME/.xsessionrc > /dev/null << 'EOF'
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
EOF
```

Keep their session alive after disconnect:

```bash
sudo loginctl enable-linger "$USERNAME"
```

Repeat Step 6 for every additional user. No xRDP restart needed between users.

---

## Step 7 — UFW: open SSH + your RDP port

```bash
sudo ufw allow 22/tcp           comment 'SSH'
sudo ufw allow ${RDP_PORT}/tcp  comment 'xRDP'
sudo ufw --force enable
sudo ufw status verbose
```

> **Strongly recommended:** restrict to known source networks if you can,
> e.g.
> `sudo ufw allow from 203.0.113.0/24 to any port ${RDP_PORT} proto tcp`
> and `sudo ufw delete` the blanket rule. Public RDP without a source filter
> is loud and noisy even with fail2ban.

---

## Step 8 — fail2ban: ban brute-force attempts

Install:

```bash
sudo apt install -y fail2ban
```

xRDP doesn't ship with a default fail2ban filter. Create one:

```bash
sudo tee /etc/fail2ban/filter.d/xrdp.conf > /dev/null << 'EOF'
[Definition]
failregex = ^.*\[ERROR\] .*authentication failed.*from <HOST>.*$
            ^.*\[INFO \] .*login failed for user .* from <HOST>.*$
            ^.*\[ERROR\] .*scp_v0s_accept: not pwd.*$
ignoreregex =
EOF
```

Create a jail that watches `/var/log/xrdp-sesman.log`:

```bash
sudo tee /etc/fail2ban/jail.d/xrdp.local > /dev/null << EOF
[xrdp]
enabled  = true
port     = ${RDP_PORT}
filter   = xrdp
logpath  = /var/log/xrdp-sesman.log
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
```

Start it:

```bash
sudo systemctl enable --now fail2ban
sudo fail2ban-client status xrdp
```

> If the `status xrdp` command errors with "jail not found", check
> `sudo fail2ban-client -d 2>&1 | grep -i error` — usually a typo in the
> filter regex or a missing log file (xRDP creates it on first connection).

---

## Step 9 — Start xRDP

```bash
sudo systemctl enable --now xrdp
sudo systemctl status xrdp --no-pager
```

It should be `active (running)`. Listening port check:

```bash
sudo ss -tlnp | grep -E "(:${RDP_PORT}|xrdp)"
```

You should see xrdp listening on `${RDP_PORT}` and `xrdp-sesman` on `127.0.0.1:3350`.

---

## Step 10 — Connect from your RDP client

| Client | Where to type host |
|---|---|
| **Windows** — `mstsc.exe` | `Computer:` → `your.server.ip:33890` |
| **macOS** — Microsoft Remote Desktop | "PC name" → `your.server.ip:33890` |
| **Linux** — Remmina | Server: `your.server.ip:33890`, Protocol: RDP |
| **iOS / Android** — MS RD Client | Add PC → `your.server.ip:33890` |

Username/password = the Linux account you created in Step 6.
Pick "Xorg" if the xRDP login screen offers a session dropdown.

---

## Adding more users later

```bash
USERNAME=bob

sudo adduser "$USERNAME"
sudo usermod -aG ssl-cert "$USERNAME"
sudo -u "$USERNAME" tee /home/$USERNAME/.xsessionrc > /dev/null << 'EOF'
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
EOF
sudo loginctl enable-linger "$USERNAME"
```

Done. Bob can RDP in immediately.

---

## Optional: silence the "color management" popup

Some XFCE sessions show a PolicyKit popup ("authentication required to
create color profile") on every login. To suppress:

```bash
sudo tee /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla > /dev/null << 'EOF'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
```

No service restart needed.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Black screen after login | No `~/.xsessionrc` | Re-do Step 6 |
| Login screen → instant disconnect | xrdp can't read TLS key | `sudo adduser xrdp ssl-cert`, restart xrdp |
| "Connection refused" from client | Wrong port / UFW / cloud firewall | `sudo ss -tlnp \| grep xrdp`, `sudo ufw status`, check cloud-provider security group |
| Slow / glitchy desktop | Xvnc backend instead of Xorg | Ensure `xorgxrdp` is installed; pick "Xorg" in xrdp login dropdown |
| Reconnect lands in a new empty session | `KillDisconnected=true` or no linger | Re-do Steps 5 and 6 |
| fail2ban jail "not found" | Filter regex typo / log file missing | `sudo fail2ban-client -d`, tail `/var/log/fail2ban.log` |
| Polkit popups every login | Default colord rules | Apply the optional polkit snippet above |
| `MaxSessions` hit unexpectedly | Too low for RAM, or zombies | `loginctl list-sessions`, kill stale sessions, raise the cap |

Log files worth knowing:

- `/var/log/xrdp.log` — connection / TLS / port
- `/var/log/xrdp-sesman.log` — auth, session spawn, the file fail2ban watches
- `/var/log/fail2ban.log` — bans and unbans
- `journalctl -u xrdp -e` — service-level errors

---

## Hardening checklist (do these if the VM is exposed to the open internet)

- [ ] Custom RDP port (Step 4) ✅
- [ ] UFW restricted to known source networks (Step 7 note)
- [ ] fail2ban xrdp jail active (Step 8) ✅
- [ ] Strong passwords for every account (`adduser` enforces a minimum, but use a passphrase)
- [ ] No `root` RDP login — keep `/etc/ssh/sshd_config: PermitRootLogin no` and don't add `root` to xrdp_users
- [ ] Keep the host patched (`unattended-upgrades`)
- [ ] Snapshot / image the VM before changing xrdp config — package upgrades occasionally rewrite `xrdp.ini` and `sesman.ini`
