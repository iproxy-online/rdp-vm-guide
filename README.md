# xrdp-multiuser-guide

Get a Windows-style remote desktop on a cloud VM. Multi-user, Ubuntu 26.04, RDP over the plain internet — connect with any RDP client.

---

## Option A — Brand-new cloud VM (recommended)

Pick your provider. Each one ends the same way: paste a file, boot, connect.

### Before you start

1. Open [`cloud-init.yml`](cloud-init.yml) → click the **Raw** button → **Ctrl-A, Ctrl-C** to copy it all.
2. Paste it into a text editor (Notepad is fine).
3. Edit the block marked **EDIT HERE**:
   - `xrdp_users:` — change names and pick strong passwords.
   - `rdp_port:` — leave at `33890` unless you have a reason.
   - `ufw_allow_from:` — leave `any`, or restrict to your home IP/CIDR.
4. Select all → copy again. You'll paste this customised version below.

### DigitalOcean

1. **Create → Droplets**.
2. **Region**: pick the one closest to your users.
3. **OS**: Ubuntu **26.04 (LTS) x64**.
4. **CPU options**: at least **2 GB RAM** per concurrent user.
5. **Authentication**: a root password is fine — you won't need it.
6. Open **Advanced options** → tick **Add Initialization scripts (cloud-init)** → paste your edited file.
7. **Create Droplet**. Wait ~5 min after it shows as Active.

### Vultr

1. **Deploy → Deploy New Server**.
2. **Server Type**: Cloud Compute.
3. **Location**: closest to your users.
4. **Image**: Ubuntu **26.04 LTS x64**.
5. **Plan**: at least 2 GB RAM per user.
6. Scroll to **Additional Features** → expand **User Data** → paste your edited file.
7. **Deploy Now**. Wait ~5 min after it shows as Running.

### Hetzner Cloud

1. **+ Add Server**.
2. **Location**: closest to your users.
3. **Image**: Ubuntu **26.04**.
4. **Type**: at least 2 GB RAM (CX22 or larger).
5. Scroll to **Cloud config** → paste your edited file.
6. **Create & Buy now**. Wait ~5 min after the green dot appears.

### AWS / Azure / GCP / OVH / others

Any provider with a "User Data" / "Custom data" / "Startup script" field for a fresh Ubuntu **26.04** VM works the same way: paste the edited `cloud-init.yml`, boot.

---

## Connect with RDP

After ~5 minutes the VM is ready.

**Windows** — Start menu → **Remote Desktop Connection** (mstsc) →
&nbsp;&nbsp;&nbsp;&nbsp;Computer: `<vm-public-ip>:33890` → Connect → username/password from your `cloud-init.yml`.

**macOS** — App Store → **Microsoft Remote Desktop** → Add PC → same host/port.

**iPhone / Android** — **RD Client** app from the store → same host/port.

---

## Option B — Already have an Ubuntu 26.04 VM?

SSH in and run:

```bash
git clone https://github.com/iproxy-online/xrdp-multiuser-guide.git
cd xrdp-multiuser-guide
sudo ./setup-and-run.sh
```

You'll be asked for the RDP port, source CIDR, and a comma-separated user list. Set each user's password afterwards with `sudo passwd <name>`.

---

## Troubles?

- **Can't connect at all** — your provider may have its own firewall on top of the VM. Make sure inbound TCP on your `rdp_port` (default 33890) is allowed.
- **Connects, then black screen** — wait another minute on first login (XFCE first-run setup), then reconnect.
- **Wrong password** — `cloud-init.yml` was pasted before you edited it. Destroy the VM and start again with an edited copy.
