# xrdp-multiuser-guide

One-shot installer for a multi-user XFCE remote desktop on **Ubuntu 26.04**,
reachable over the plain internet with any RDP client. No Cloudflare, no
Apache, no SSH tunnel.

Ships:

- `site.yml` — standalone Ansible playbook (idempotent)
- `setup-and-run.sh` — wrapper: preflight, prompts, installs Ansible, runs the play locally
- this README

---

## Prerequisites

- Fresh **Ubuntu Server 26.04 LTS**, sudo access
- Public IP, port `22` open in the cloud provider's firewall
- ≥ 2 GB RAM per concurrent RDP user
- Your cloud provider's firewall / security group will need the chosen RDP port opened too — UFW alone won't help if the VM is behind one

---

## Quick start

```bash
git clone https://github.com/iproxy-online/xrdp-multiuser-guide.git
cd xrdp-multiuser-guide
sudo ./setup-and-run.sh
```

You'll be prompted for:

| Prompt | Default | Notes |
|---|---|---|
| RDP port | `33890` | Anything in `1024–65535`. Moving off `3389` cuts ~99% of dumb scans. |
| Allow from | `any` | A CIDR like `203.0.113.0/24` is **strongly** recommended. `any` = open to the whole internet. |
| Usernames | — | Comma-separated, e.g. `alice,bob`. Re-run with the full list to add more later. |

Or non-interactive:

```bash
sudo RDP_PORT=33890 ALLOW_FROM=any USERS=alice,bob ./setup-and-run.sh
```

After it finishes, set each user's password:

```bash
sudo passwd alice
sudo passwd bob
```

Connect from any RDP client — Windows `mstsc`, macOS Microsoft Remote Desktop,
Linux Remmina, iOS/Android MS RD Client. Host: `your.ip:33890`.

---

## What the playbook does

- Installs XFCE, xrdp, xorgxrdp, dbus-x11, fail2ban, ufw
- Adds `xrdp` to `ssl-cert` (so it can read its TLS key)
- Binds xrdp to your chosen port (`/etc/xrdp/xrdp.ini` → `port=tcp://0.0.0.0:<PORT>`)
- Tunes `sesman.ini` for persistent multi-user sessions
  (`MaxSessions=50`, `KillDisconnected=false`, no idle/disconnect timeouts)
- Creates each user, drops a per-user `~/.xsessionrc` that exec's `startxfce4`
- `loginctl enable-linger` per user so sessions survive client disconnect
- UFW: allow `22/tcp` and the RDP port (optionally source-restricted), default deny
- fail2ban: custom filter + jail watching `/var/log/xrdp-sesman.log`
  (5 fails in 10 min → 1 h ban)
- Enables and starts `xrdp` and `fail2ban`

Idempotent — re-running with the same inputs reports `changed=0`. Re-running
with a longer userlist only adds the new ones.

---

## Adding more users later

Just re-run with the full list:

```bash
sudo USERS=alice,bob,carol ./setup-and-run.sh
```

Existing users are left alone; `carol` gets created, gets `.xsessionrc`,
gets lingering enabled.

---

## Running the playbook directly (without the wrapper)

```bash
sudo apt install -y ansible
sudo ansible-playbook -i 'localhost,' -c local site.yml \
  -e rdp_port=33890 \
  -e ufw_allow_from=any \
  -e '{"xrdp_users":["alice","bob"]}'
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Black screen after login | `~/.xsessionrc` missing or wrong owner | Re-run the script — playbook writes it correctly per user |
| Login screen → instant disconnect | xrdp can't read TLS key | Already handled by the play (`ssl-cert` group); check `journalctl -u xrdp -e` |
| "Connection refused" from client | Cloud firewall, UFW, or wrong port | `sudo ss -tlnp \| grep xrdp`, `sudo ufw status`, check provider's security group |
| Slow / laggy desktop | Falling back to Xvnc | Ensure `xorgxrdp` is installed; pick "Xorg" if xrdp shows a session dropdown |
| Reconnect → fresh empty session | Linger off or `KillDisconnected=true` | Re-run; playbook sets both correctly |
| `fail2ban-client status xrdp` says "not found" | Filter typo / log file missing | `sudo fail2ban-client -d 2>&1 \| grep -i error`, tail `/var/log/fail2ban.log` |

Logs worth knowing:

- `/var/log/xrdp.log` — connection, TLS, port binding
- `/var/log/xrdp-sesman.log` — auth, session spawn (fail2ban watches this)
- `/var/log/fail2ban.log` — bans and unbans
- `journalctl -u xrdp -e` / `journalctl -u fail2ban -e`

---

## Hardening checklist (open-internet RDP)

- [x] Non-default RDP port (`RDP_PORT`, default 33890)
- [ ] `ALLOW_FROM` restricted to a known CIDR (do this — `any` is loud)
- [x] fail2ban xrdp jail active
- [x] UFW default-deny
- [ ] Strong passwords for every account — use a passphrase, not `Pass1234`
- [ ] `PermitRootLogin no` in `/etc/ssh/sshd_config` (default on Ubuntu Server, but verify)
- [ ] `unattended-upgrades` enabled so the box stays patched
- [ ] Snapshot the VM before re-running this on an existing host — apt upgrades occasionally rewrite `xrdp.ini` / `sesman.ini`
