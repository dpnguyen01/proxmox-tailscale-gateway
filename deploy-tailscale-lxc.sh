#!/usr/bin/env bash
#
# deploy-tailscale-lxc.sh
#
# Create a Debian 12 LXC on Proxmox and provision Tailscale inside it,
# ready to act as an EXIT NODE and SUBNET ROUTER.
#
# RUN THIS ON THE PROXMOX HOST (as root).
#
# What it does:
#   1. Downloads the Debian 12 LXC template if missing.
#   2. Creates the container with the resources you specify.
#   3. Enables the TUN device inside the container (required by Tailscale),
#      and nesting (needed for the systemd-based tailscaled service).
#   4. Starts the container, installs Tailscale, enables IPv4 + IPv6
#      forwarding (required for exit-node / subnet routing).
#   5. Brings Tailscale up advertising your exit node and the subnet routes.
#
# After it runs you approve the node + routes in the Tailscale admin console
# (https://login.tailscale.com/admin/machines) -- "Edit route settings" ->
# enable the subnet routes and "Use as exit node".
#
# Re-run safe: skips template download and container creation if they exist.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG -- edit these, or override any of them on the command line as
#          KEY=value environment variables, e.g.:
#          CTID=150 SUBNET_ROUTES="10.0.0.0/24,192.168.1.0/24" ./deploy-tailscale-lxc.sh
# ---------------------------------------------------------------------------

# --- Container identity / resources ---
CTID="${CTID:-150}"                       # Proxmox container ID (must be unused)
HOSTNAME="${HOSTNAME_CT:-tailscale-gw}"   # container hostname
STORAGE="${STORAGE:-local-lvm}"           # storage for the rootfs
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}" # storage holding CT templates
DISK_GB="${DISK_GB:-4}"                    # rootfs size in GB
CORES="${CORES:-1}"                        # CPU cores
MEMORY_MB="${MEMORY_MB:-512}"              # RAM in MB
SWAP_MB="${SWAP_MB:-512}"                  # swap in MB
BRIDGE="${BRIDGE:-vmbr0}"                  # network bridge
# IP config: "dhcp" or a static like "192.168.1.50/24" (set GATEWAY too)
IP_CONFIG="${IP_CONFIG:-dhcp}"
GATEWAY="${GATEWAY:-}"                      # e.g. 192.168.1.1 (only if static IP)

# --- Unprivileged vs privileged ---
# Unprivileged (1) is safer and works fine for Tailscale once TUN is mapped.
UNPRIVILEGED="${UNPRIVILEGED:-1}"

# --- Tailscale config ---
# Auth key from https://login.tailscale.com/admin/settings/keys
# Reusable + pre-authorized is handy for re-deploys. REQUIRED for unattended up.
TS_AUTHKEY="${TS_AUTHKEY:-}"
# Comma-separated subnets this node advertises for subnet routing.
# Set to the LAN(s) behind this box, e.g. "192.168.1.0/24,10.10.0.0/16"
SUBNET_ROUTES="${SUBNET_ROUTES:-192.168.1.0/24}"
# Advertise as an exit node (1) or not (0)
ADVERTISE_EXIT_NODE="${ADVERTISE_EXIT_NODE:-1}"
# Extra flags passed verbatim to `tailscale up` (e.g. --accept-dns=false)
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:---ssh}"

# --- Template ---
# Leave empty to auto-pick the LATEST debian-*-standard template (tracks the
# newest stable release). Set explicitly to pin, e.g.
# TEMPLATE_NAME="debian-13-standard_13.0-1_amd64.tar.zst"
TEMPLATE_NAME="${TEMPLATE_NAME:-}"

# ---------------------------------------------------------------------------
# Implementation
# ---------------------------------------------------------------------------

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this on the Proxmox host as root."
command -v pct >/dev/null || die "'pct' not found -- this must run on a Proxmox VE host."

# 1. Template --------------------------------------------------------------
pveam update >/dev/null 2>&1 || true

if [[ -z "$TEMPLATE_NAME" ]]; then
    log "Resolving latest Debian standard template from pveam."
    TEMPLATE_NAME="$(pveam available --section system \
        | awk '{print $2}' \
        | grep -E '^debian-[0-9]+-standard' \
        | sort -V | tail -n1)"
    [[ -n "$TEMPLATE_NAME" ]] || die "Could not resolve a Debian template. See: pveam available --section system"
    log "Latest Debian template: $TEMPLATE_NAME"
fi

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
    log "Template $TEMPLATE_NAME not present; downloading."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" \
        || die "Failed to download $TEMPLATE_NAME. List options with: pveam available --section system"
else
    log "Template $TEMPLATE_NAME already present."
fi
TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

# 2. Create container ------------------------------------------------------
if pct status "$CTID" >/dev/null 2>&1; then
    warn "Container $CTID already exists; skipping creation."
else
    log "Creating container $CTID ($HOSTNAME)."
    NET0="name=eth0,bridge=${BRIDGE}"
    if [[ "$IP_CONFIG" == "dhcp" ]]; then
        NET0="${NET0},ip=dhcp"
    else
        NET0="${NET0},ip=${IP_CONFIG}"
        [[ -n "$GATEWAY" ]] && NET0="${NET0},gw=${GATEWAY}"
    fi

    pct create "$CTID" "$TEMPLATE_REF" \
        --hostname "$HOSTNAME" \
        --cores "$CORES" \
        --memory "$MEMORY_MB" \
        --swap "$SWAP_MB" \
        --rootfs "${STORAGE}:${DISK_GB}" \
        --net0 "$NET0" \
        --unprivileged "$UNPRIVILEGED" \
        --features nesting=1 \
        --onboot 1 \
        --ostype debian
fi

# 3. Enable TUN device + lxc.cap for the container -------------------------
# Tailscale needs /dev/net/tun. We append the mount + cgroup allow to the
# container's config on the host. Idempotent: only add lines not present.
CONF="/etc/pve/lxc/${CTID}.conf"
log "Ensuring TUN device access in $CONF"

add_conf_line() {
    local line="$1"
    grep -qxF "$line" "$CONF" || echo "$line" >> "$CONF"
}

add_conf_line "lxc.cgroup2.devices.allow: c 10:200 rwm"
add_conf_line "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"

log "Restarting container to apply device config."
pct stop "$CTID" >/dev/null 2>&1 || true
pct start "$CTID"

# Give it a moment to get networking up.
sleep 5

# 4. Provision inside the container ----------------------------------------
log "Installing Tailscale inside container $CTID."

# Enable IP forwarding (persistent) -- required for subnet routing + exit node.
pct exec "$CTID" -- bash -c '
set -e
cat >/etc/sysctl.d/99-tailscale.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null
'

# Install Tailscale from the official repo.
pct exec "$CTID" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates >/dev/null
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
'

# 5. Bring Tailscale up ----------------------------------------------------
UP_ARGS=(--advertise-routes="${SUBNET_ROUTES}")
[[ "$ADVERTISE_EXIT_NODE" == "1" ]] && UP_ARGS+=(--advertise-exit-node)
# shellcheck disable=SC2206
[[ -n "$TS_EXTRA_ARGS" ]] && UP_ARGS+=($TS_EXTRA_ARGS)

if [[ -n "$TS_AUTHKEY" ]]; then
    log "Running 'tailscale up' with auth key (unattended)."
    pct exec "$CTID" -- tailscale up \
        --authkey="$TS_AUTHKEY" \
        "${UP_ARGS[@]}"
    log "Tailscale is up. Node status:"
    pct exec "$CTID" -- tailscale status || true
else
    warn "No TS_AUTHKEY set -- running 'tailscale up' interactively."
    warn "A login URL will print below; open it in a browser to authenticate."
    pct exec "$CTID" -- tailscale up "${UP_ARGS[@]}" || true
fi

cat <<EOF

------------------------------------------------------------------------
Done. Container $CTID ($HOSTNAME) is provisioned.

Advertised subnet routes : ${SUBNET_ROUTES}
Advertised exit node     : $( [[ "$ADVERTISE_EXIT_NODE" == "1" ]] && echo yes || echo no )

NEXT STEP (one-time, in the Tailscale admin console):
  https://login.tailscale.com/admin/machines
  Find "$HOSTNAME" -> "..." -> Edit route settings:
    * enable the subnet routes
    * tick "Use as exit node"

Then disable key expiry on this node (it's infrastructure):
  admin console -> the node -> Disable key expiry.

Verify from the container:
  pct exec $CTID -- tailscale status
  pct exec $CTID -- tailscale netcheck
------------------------------------------------------------------------
EOF
