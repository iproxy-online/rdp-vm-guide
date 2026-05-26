#!/usr/bin/env bash
# Granny-clear one-shot installer for multi-user xRDP on Ubuntu 26.04.
#
# Usage:
#   sudo ./setup-and-run.sh                # interactive prompts
#   sudo RDP_PORT=33890 ALLOW_FROM=any USERS=alice,bob ./setup-and-run.sh   # non-interactive
#
# Idempotent: safe to re-run (e.g. to add more users — just include the
# whole list each time, existing users are left alone).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT="$HERE/cloud-init.yml"
PLAYBOOK="$(mktemp /tmp/xrdp-site.XXXXXX.yml)"
trap 'rm -f "$PLAYBOOK"' EXIT

# ---- 0. preflight -----------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root (sudo $0)" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "ERROR: /etc/os-release not found — is this Ubuntu?" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]] || ! printf '%s\n' "24.04" "${VERSION_ID:-0}" | sort -V -C; then
  echo "ERROR: Ubuntu 24.04 or newer required (got ${ID:-?} ${VERSION_ID:-?})." >&2
  exit 1
fi

if [[ ! -f "$CLOUD_INIT" ]]; then
  echo "ERROR: cloud-init.yml not found next to this script ($CLOUD_INIT)" >&2
  exit 1
fi

# ---- 1. gather inputs -------------------------------------------------------

RDP_PORT="${RDP_PORT:-}"
ALLOW_FROM="${ALLOW_FROM:-}"
USERS="${USERS:-}"

if [[ -z "$RDP_PORT" ]]; then
  read -rp "RDP port [33890]: " RDP_PORT
  RDP_PORT="${RDP_PORT:-33890}"
fi

if [[ -z "$ALLOW_FROM" ]]; then
  echo "Restrict RDP to a source network? (CIDR like 203.0.113.0/24, or 'any')"
  read -rp "Allow from [any]: " ALLOW_FROM
  ALLOW_FROM="${ALLOW_FROM:-any}"
fi

if [[ -z "$USERS" ]]; then
  read -rp "Comma-separated usernames to create (e.g. alice,bob): " USERS
fi

if [[ -z "$USERS" ]]; then
  echo "ERROR: at least one username required" >&2
  exit 1
fi

# ---- 2. validate ------------------------------------------------------------

if ! [[ "$RDP_PORT" =~ ^[0-9]+$ ]] || (( RDP_PORT < 1024 || RDP_PORT > 65535 )); then
  echo "ERROR: RDP_PORT must be a number in 1024..65535 (got '$RDP_PORT')" >&2
  exit 1
fi

# normalise comma list -> JSON array, dropping blanks
USERS_JSON="$(
  python3 - <<PY
import json, sys
xs = [u.strip() for u in "$USERS".split(",") if u.strip()]
if not xs:
    sys.exit("ERROR: no valid usernames after parsing")
for u in xs:
    if not u.replace("-", "").replace("_", "").isalnum() or not u[0].isalpha():
        sys.exit(f"ERROR: invalid username: {u!r}")
print(json.dumps(xs))
PY
)"

# ---- 3. install ansible + python3-yaml --------------------------------------

NEED_INSTALL=()
command -v ansible-playbook >/dev/null 2>&1 || NEED_INSTALL+=(ansible)
python3 -c "import yaml" 2>/dev/null            || NEED_INSTALL+=(python3-yaml)
if (( ${#NEED_INSTALL[@]} )); then
  echo ">>> installing: ${NEED_INSTALL[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${NEED_INSTALL[@]}"
fi

# ---- 4. extract the playbook from cloud-init.yml ----------------------------
# cloud-init.yml is the single source of truth. The playbook is embedded in it
# under write_files[/opt/xrdp-multiuser/site.yml]; we pull it out into a temp
# file so ansible-playbook can run it. site.yml is intentionally NOT shipped.

python3 - "$CLOUD_INIT" "$PLAYBOOK" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    cfg = yaml.safe_load(f)
for entry in cfg.get("write_files", []) or []:
    if entry.get("path") == "/opt/xrdp-multiuser/site.yml":
        with open(dst, "w") as out:
            out.write(entry["content"])
        sys.exit(0)
sys.exit("ERROR: embedded site.yml not found in cloud-init.yml write_files")
PY

# ---- 5. run the playbook ----------------------------------------------------

echo
echo ">>> running playbook"
echo "    port:       $RDP_PORT"
echo "    allow from: $ALLOW_FROM"
echo "    users:      $USERS_JSON"
echo

EXTRA_VARS="$(
  python3 - <<PY
import json, sys
print(json.dumps({
    "rdp_port": int("$RDP_PORT"),
    "ufw_allow_from": "$ALLOW_FROM",
    "xrdp_users": json.loads('''$USERS_JSON'''),
}))
PY
)"

ansible-playbook \
  -i 'localhost,' \
  -c local \
  -e "$EXTRA_VARS" \
  "$PLAYBOOK"

# ---- 6. post-run hints ------------------------------------------------------

PUBLIC_IP="$(python3 -c 'import urllib.request as u; print(u.urlopen("https://api.ipify.org", timeout=3).read().decode())' 2>/dev/null || hostname -I | awk '{print $1}')"

cat <<EOF

============================================================
xRDP is up. Next steps:

1. Set a password for each user (interactive):
EOF
# shellcheck disable=SC2001
for u in $(echo "$USERS" | sed 's/,/ /g'); do
  echo "     sudo passwd $u"
done
cat <<EOF

2. Make sure your cloud provider's firewall / security group
   allows inbound TCP ${RDP_PORT} (UFW alone is not enough).

3. Connect from any RDP client:
     host: ${PUBLIC_IP}
     port: ${RDP_PORT}
     user: <one of the names above>

4. To add more users later, just re-run this script and
   include the full list (existing users are skipped).

5. Sanity checks:
     sudo systemctl status xrdp
     sudo fail2ban-client status xrdp
     sudo ufw status verbose
============================================================
EOF
