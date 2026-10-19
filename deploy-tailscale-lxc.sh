#!/usr/bin/env bash
#
# deploy-tailscale-lxc.sh
#
# Create and MAINTAIN a Debian LXC on Proxmox running Tailscale as an
# EXIT NODE and SUBNET ROUTER. Tracks the latest Debian standard template.
#
# RUN THIS ON THE PROXMOX HOST (as root).
#
# ---------------------------------------------------------------------------
# MODES  (first positional arg, or MODE=... ; default: install)
# ---------------------------------------------------------------------------
#   install      Create the container if absent, map the TUN device, install
#                Tailscale, enable forwarding, bring it up. Idempotent: safe to
#                re-run; skips steps already done.
#
#   upgrade      Upgrade an EXISTING container: upgrade the Tailscale package
#                to the latest, re-apply forwarding + the current `tailscale up`
#                config, and (optionally, APT_DIST_UPGRADE=1) apt dist-upgrade
#                the OS. Does NOT recreate the container and does NOT do a
#                Debian major-version jump (see NOTE below).
#
#   reconfigure  Re-apply `tailscale up` with the CURRENT SUBNET_ROUTES /
#                ADVERTISE_EXIT_NODE / TS_EXTRA_ARGS on the existing node.
#                No package changes. Use after changing routes or toggling
#                the exit node. Tailscale 'up' is declarative and reconciles.
#
#   status       Print container + Tailscale status. Read-only.
#
# NOTE on Debian MAJOR upgrades (e.g. 12 -> 13): deliberately NOT automated.
# In-place dist release upgrades of an LXC are risky; the clean path is to
# build a FRESH container on the new template and re-point Tailscale. To do
# that: pick a new CTID, run `install` (it auto-selects the latest template),
# then retire the old container. `upgrade` only moves packages within the
# installed release.
#
# Examples:
#   ./deploy-tailscale-lxc.sh install
#   SUBNET_ROUTES="10.0.0.0/24,192.168.1.0/24" ./deploy-tailscale-lxc.sh reconfigure
#   APT_DIST_UPGRADE=1 ./deploy-tailscale-lxc.sh upgrade
#   MODE=status ./deploy-tailscale-lxc.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG -- edit, or override as KEY=value env vars.
# ---------------------------------------------------------------------------

# --- Mode ---
MODE="${1:-${MODE:-install}}"

# --- Interactive setup detection ---
# Record which settings the caller already provided via env var, BEFORE we
# apply defaults below. On 'install', any setting NOT provided is prompted for
# in an interactive setup screen (unless NONINTERACTIVE=1 or there is no TTY).
NONINTERACTIVE="${NONINTERACTIVE:-0}"
declare -A _PROVIDED=()
for _v in CTID HOSTNAME_CT STORAGE TEMPLATE_STORAGE DISK_GB CORES MEMORY_MB \
          SWAP_MB BRIDGE IP_CONFIG GATEWAY UNPRIVILEGED TS_AUTHKEY \
          SUBNET_ROUTES ADVERTISE_EXIT_NODE TS_EXTRA_ARGS TEMPLATE_NAME; do
    [[ -n "${!_v+set}" ]] && _PROVIDED[$_v]=1
done

# --- Container identity / resources ---
# Empty => auto-pick the next free Proxmox container ID (>= 100).
CTID="${CTID:-}"                          # Proxmox container ID (blank = next free)
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
UNPRIVILEGED="${UNPRIVILEGED:-1}"          # 1 = unprivileged (recommended)

# --- Tailscale config ---
TS_AUTHKEY="${TS_AUTHKEY:-}"               # auth key (unattended up); optional on upgrade/reconfigure
SUBNET_ROUTES="${SUBNET_ROUTES:-192.168.1.0/24}"   # comma-separated subnets
ADVERTISE_EXIT_NODE="${ADVERTISE_EXIT_NODE:-1}"    # 1 = advertise exit node
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}"         # extra `tailscale up` flags (e.g. --ssh to enable Tailscale SSH)

# --- Upgrade behavior ---
APT_DIST_UPGRADE="${APT_DIST_UPGRADE:-0}"  # 1 = also apt dist-upgrade the OS on 'upgrade'

# --- Console ---
# 1 = auto-login root on the Proxmox console tty (web-UI Console button /
# `pct console`), so it opens a shell with no login prompt. `pct enter` is
# already password-less; this makes the console match it. Anyone with Proxmox
# access can already `pct enter` as root, so this does not widen that.
CONSOLE_AUTOLOGIN="${CONSOLE_AUTOLOGIN:-1}"

# --- Template ---
# Empty => auto-pick the latest debian-*-standard template. Pin to override.
TEMPLATE_NAME="${TEMPLATE_NAME:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_host() {
    [[ $EUID -eq 0 ]] || die "Run this on the Proxmox host as root."
    command -v pct >/dev/null || die "'pct' not found -- this must run on a Proxmox VE host."
}

# The host's CT-template architecture token, as it appears in template names
# (amd64 / arm64). A container's /sbin/init must match the host CPU or it fails
# to start with "Exec format error" -- so we only ever pick a template whose
# arch matches the host. Prefer dpkg's view (Debian's own arch name); fall back
# to mapping `uname -m`.
host_template_arch() {
    local a=""
    if command -v dpkg >/dev/null; then
        a="$(dpkg --print-architecture 2>/dev/null)"
    fi
    if [[ -z "$a" ]]; then
        case "$(uname -m)" in
            x86_64|amd64)        a="amd64" ;;
            aarch64|arm64)       a="arm64" ;;
            armv7l|armhf)        a="armhf" ;;
            *)                   a="$(uname -m)" ;;
        esac
    fi
    echo "$a"
}

# Lowest free container ID >= 100. Prefer Proxmox's own allocator; fall back to
# scanning `pct list` if pvesh is unavailable.
next_free_ctid() {
    local id=""
    if command -v pvesh >/dev/null; then
        id="$(pvesh get /cluster/nextid 2>/dev/null)" || id=""
    fi
    if [[ -z "$id" ]]; then
        local used last=99 n
        used="$(pct list 2>/dev/null | awk 'NR>1{print $1}' | sort -n)"
        for n in $used; do [[ "$n" -ge 100 ]] && last="$n"; done
        id=$(( last + 1 ))
        # Handle gaps: make sure the chosen ID is really free.
        while pct status "$id" >/dev/null 2>&1; do id=$(( id + 1 )); done
    fi
    echo "$id"
}

# Resolve CTID to the next free ID when the caller left it blank.
resolve_ctid() {
    if [[ -z "$CTID" ]]; then
        CTID="$(next_free_ctid)"
        [[ -n "$CTID" ]] || die "Could not determine a free container ID."
        log "No CTID given; using next free container ID: $CTID"
    fi
}

ct_exists()  { pct status "$CTID" >/dev/null 2>&1; }
ct_running() { pct status "$CTID" 2>/dev/null | grep -q running; }

require_ct() {
    [[ -n "$CTID" ]] || die "No CTID set. '$MODE' needs an existing container ID, e.g. CTID=150 ... $MODE"
    ct_exists || die "Container $CTID does not exist. Run 'install' first."
}

ensure_ct_running() {
    ct_running || { log "Starting container $CTID."; pct start "$CTID"; sleep 5; }
}

# Build the `tailscale up` argument array from current config.
build_up_args() {
    UP_ARGS=(--advertise-routes="${SUBNET_ROUTES}")
    [[ "$ADVERTISE_EXIT_NODE" == "1" ]] && UP_ARGS+=(--advertise-exit-node)
    # shellcheck disable=SC2206
    [[ -n "$TS_EXTRA_ARGS" ]] && UP_ARGS+=($TS_EXTRA_ARGS)
}

# ---------------------------------------------------------------------------
# Interactive setup screen (install mode only)
# ---------------------------------------------------------------------------

# prompt VARNAME "Question" [provided-flag-key] [secret]
# Only prompts when the setting was NOT provided via env var. Shows the current
# default in brackets; empty answer keeps it. `secret=1` hides input.
_prompt() {
    local var="$1" question="$2" provided_key="${3:-$1}" secret="${4:-0}"
    [[ -n "${_PROVIDED[$provided_key]:-}" ]] && return 0   # caller already set it
    local current="${!var}" answer=""
    if [[ "$secret" == "1" ]]; then
        printf '%s [%s]: ' "$question" "${current:+(set)}" >/dev/tty
        read -r -s answer </dev/tty || true; echo >/dev/tty
    else
        printf '%s [%s]: ' "$question" "$current" >/dev/tty
        read -r answer </dev/tty || true
    fi
    # Keep the default when answer is empty. Must not let a false test be the
    # function's exit status -- under `set -e` that would abort the script.
    [[ -n "$answer" ]] && printf -v "$var" '%s' "$answer"
    return 0
}

_prompt_yesno() {
    local var="$1" question="$2" provided_key="${3:-$1}"
    [[ -n "${_PROVIDED[$provided_key]:-}" ]] && return 0
    local def="no"; [[ "${!var}" == "1" ]] && def="yes"
    local answer=""
    printf '%s (yes/no) [%s]: ' "$question" "$def" >/dev/tty
    read -r answer </dev/tty || true
    case "${answer,,}" in
        y|yes) printf -v "$var" '1' ;;
        n|no)  printf -v "$var" '0' ;;
        "")    : ;;   # keep default
        *)     warn "Unrecognized '$answer'; keeping $def." ;;
    esac
    return 0
}

interactive_setup() {
    # Skip when explicitly non-interactive, or when no controlling terminal is
    # available to read from. We read prompts from /dev/tty (not stdin) so the
    # screen works even when launched as `bash -c "$(curl ...)"`, where the
    # script's stdin is NOT the keyboard.
    [[ "$NONINTERACTIVE" == "1" ]] && return
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        warn "No controlling terminal -- skipping interactive setup, using env/defaults."
        return
    fi
    exec 3>&-   # close probe fd; helpers open /dev/tty directly

    echo
    echo "======================================================================"
    echo " Tailscale LXC setup  --  press Enter to keep the [default] shown"
    echo "======================================================================"
    echo " A Tailscale exit-node / subnet-router is a LIGHT workload (userspace"
    echo " WireGuard, no GUI/DB). The defaults below suit a typical home uplink;"
    echo " each prompt notes when to go higher."
    echo

    # CTID: blank default means "auto-pick the next free ID" -- show that.
    if [[ -z "${_PROVIDED[CTID]:-}" ]]; then
        local _suggested_ctid; _suggested_ctid="$(next_free_ctid 2>/dev/null || true)"
        printf 'Container ID (CTID) -- blank = next free [%s]: ' "${_suggested_ctid:-auto}" >/dev/tty
        local _ctid_ans; read -r _ctid_ans </dev/tty || true
        [[ -n "$_ctid_ans" ]] && CTID="$_ctid_ans"
    fi

    _prompt HOSTNAME  "Container hostname" HOSTNAME_CT
    _prompt STORAGE   "Rootfs storage"

    echo "  (disk: ~2GB used by Debian+Tailscale; 4GB leaves room for logs/upgrades)"
    _prompt DISK_GB   "Disk size (GB)"

    echo "  (cores: 1 saturates a typical home uplink; use 2 only for >~500Mbps or a busy exit node)"
    _prompt CORES     "CPU cores"

    echo "  (memory: tailscaled idles ~50-100MB; 512 is comfortable, 256 is the floor)"
    _prompt MEMORY_MB "Memory (MB)"

    echo "  (swap: a small safety net vs the OOM killer; matching RAM at 512 is plenty)"
    _prompt SWAP_MB   "Swap (MB)"

    _prompt BRIDGE    "Network bridge"

    # Networking: dhcp or static
    if [[ -z "${_PROVIDED[IP_CONFIG]:-}" ]]; then
        local ipmode
        printf 'Network: dhcp or static? [%s]: ' "$( [[ "$IP_CONFIG" == dhcp ]] && echo dhcp || echo static )" >/dev/tty
        read -r ipmode </dev/tty || true
        case "${ipmode,,}" in
            static)
                printf 'Static IP with CIDR (e.g. 192.168.1.50/24): ' >/dev/tty
                read -r IP_CONFIG </dev/tty || true
                [[ -z "${_PROVIDED[GATEWAY]:-}" ]] && { printf 'Gateway (e.g. 192.168.1.1): ' >/dev/tty; read -r GATEWAY </dev/tty || true; }
                ;;
            dhcp|"") IP_CONFIG="dhcp" ;;
            *) warn "Unrecognized '$ipmode'; using dhcp."; IP_CONFIG="dhcp" ;;
        esac
    fi

    echo "  (tip: a gateway you depend on is best on a static IP or DHCP reservation)"
    _prompt SUBNET_ROUTES "Subnet routes to advertise (comma-separated)"
    _prompt_yesno ADVERTISE_EXIT_NODE "Advertise as an exit node?"
    _prompt TS_AUTHKEY   "Tailscale auth key (blank = interactive login later)" TS_AUTHKEY 1

    echo
    echo "---------------------------- summary ---------------------------------"
    printf '  CTID            : %s\n' "${CTID:-<next free, auto>}"
    printf '  Hostname        : %s\n' "$HOSTNAME"
    printf '  Storage / disk  : %s / %sGB\n' "$STORAGE" "$DISK_GB"
    printf '  Cores / memory  : %s / %sMB\n' "$CORES" "$MEMORY_MB"
    printf '  Swap            : %sMB\n' "$SWAP_MB"
    printf '  Bridge / network: %s / %s%s\n' "$BRIDGE" "$IP_CONFIG" \
        "$( [[ "$IP_CONFIG" != dhcp && -n "$GATEWAY" ]] && echo " gw $GATEWAY" )"
    printf '  Subnet routes   : %s\n' "$SUBNET_ROUTES"
    printf '  Exit node       : %s\n' "$( [[ "$ADVERTISE_EXIT_NODE" == 1 ]] && echo yes || echo no )"
    printf '  Auth key        : %s\n' "$( [[ -n "$TS_AUTHKEY" ]] && echo "(set)" || echo "(none - interactive login)" )"
    echo "----------------------------------------------------------------------"
    local go
    printf 'Proceed with install? (yes/no) [yes]: ' >/dev/tty
    read -r go </dev/tty || true
    case "${go,,}" in
        n|no) die "Aborted by user." ;;
    esac
}

# ---------------------------------------------------------------------------
# Steps (each idempotent)
# ---------------------------------------------------------------------------

resolve_template() {
    pveam update >/dev/null 2>&1 || true
    local arch; arch="$(host_template_arch)"
    if [[ -z "$TEMPLATE_NAME" ]]; then
        log "Resolving latest Debian standard template for host arch '$arch'."
        # Filter to the HOST architecture. pveam lists templates for every
        # arch; a mismatched template builds a container whose /sbin/init the
        # host CPU cannot exec ("Exec format error"), so match arch explicitly.
        TEMPLATE_NAME="$(pveam available --section system \
            | awk '{print $2}' \
            | grep -E "^debian-[0-9]+-standard.*_${arch}\." \
            | sort -V | tail -n1)"
        if [[ -z "$TEMPLATE_NAME" ]]; then
            die "No debian-*-standard template for arch '$arch' in: pveam available --section system
(If your host arch token differs, pin it: TEMPLATE_NAME=debian-XX-standard_..._<arch>.tar.zst)"
        fi
        log "Latest Debian template: $TEMPLATE_NAME"
    else
        # A manual pin that doesn't match the host arch is the exact failure we
        # are fixing -- reject it loudly instead of building a dead container.
        if [[ "$TEMPLATE_NAME" != *"_${arch}."* ]]; then
            die "Pinned TEMPLATE_NAME '$TEMPLATE_NAME' does not match host arch '$arch'.
A container built from a mismatched-arch template fails to start with
'Exec format error'. Pick the _${arch} template, or unset TEMPLATE_NAME to
auto-resolve the right one."
        fi
    fi
    if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
        log "Template $TEMPLATE_NAME not present; downloading."
        pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" \
            || die "Failed to download $TEMPLATE_NAME. List options with: pveam available --section system"
    else
        log "Template $TEMPLATE_NAME already present."
    fi
    TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
}

create_ct() {
    if ct_exists; then
        warn "Container $CTID already exists; skipping creation."
        return
    fi
    log "Creating container $CTID ($HOSTNAME)."
    local net0="name=eth0,bridge=${BRIDGE}"
    if [[ "$IP_CONFIG" == "dhcp" ]]; then
        net0="${net0},ip=dhcp"
    else
        net0="${net0},ip=${IP_CONFIG}"
        [[ -n "$GATEWAY" ]] && net0="${net0},gw=${GATEWAY}"
    fi
    pct create "$CTID" "$TEMPLATE_REF" \
        --hostname "$HOSTNAME" \
        --cores "$CORES" \
        --memory "$MEMORY_MB" \
        --swap "$SWAP_MB" \
        --rootfs "${STORAGE}:${DISK_GB}" \
        --net0 "$net0" \
        --unprivileged "$UNPRIVILEGED" \
        --features nesting=1 \
        --onboot 1 \
        --ostype debian
}

ensure_tun() {
    # Tailscale needs /dev/net/tun; map it into the (unprivileged) container.
    local conf="/etc/pve/lxc/${CTID}.conf"
    local changed=0
    log "Ensuring TUN device access in $conf"
    _add_line() {
        grep -qxF "$1" "$conf" || { echo "$1" >> "$conf"; changed=1; }
    }
    _add_line "lxc.cgroup2.devices.allow: c 10:200 rwm"
    _add_line "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
    if [[ "$changed" == "1" ]]; then
        log "Device config changed; restarting container to apply."
        pct stop "$CTID" >/dev/null 2>&1 || true
        pct start "$CTID"
        sleep 5
    fi
}

enable_forwarding() {
    log "Enabling IPv4 + IPv6 forwarding (persistent)."
    pct exec "$CTID" -- bash -c '
set -e
cat >/etc/sysctl.d/99-tailscale.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null
'
}

enable_console_autologin() {
    [[ "$CONSOLE_AUTOLOGIN" == "1" ]] || { log "Console autologin disabled; skipping."; return; }
    log "Configuring root autologin on the container console tty."
    # Two gettys serve a Proxmox Debian LXC console:
    #   container-getty@.service -> /dev/ttyN, the unit the web-UI Console
    #                               button (xterm.js, console=lxc) attaches to.
    #   console-getty.service    -> /dev/console, used by `pct console`.
    # Both ship an interactive ExecStart of the shape:
    #   agetty -o '-- \u' --noreset --noclear - ${TERM}
    # For AUTOLOGIN the `-o '-- \u'` MUST be dropped: `\u` expands to the
    # *entered* username, which conflicts with --autologin (no username is
    # entered) and drops you at a Password: prompt. The working form is simply
    # `--autologin root --noreset --noclear - ${TERM}`. container-getty@ is a
    # TEMPLATE unit, so the drop-in goes in container-getty@.service.d (covers
    # @1/@2). ${TERM} is left for systemd/agetty to expand at runtime.
    pct exec "$CTID" -- bash -c '
set -e
for d in /etc/systemd/system/container-getty@.service.d \
         /etc/systemd/system/console-getty.service.d; do
    mkdir -p "$d"
    cat >"$d/autologin.conf" <<"CONF"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noreset --noclear - ${TERM}
CONF
done
systemctl daemon-reload
systemctl restart container-getty@1.service 2>/dev/null || true
systemctl restart console-getty.service 2>/dev/null || true
'
}

install_tailscale() {
    log "Installing Tailscale inside container $CTID (if not present)."
    pct exec "$CTID" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates >/dev/null
if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled
'
}

upgrade_tailscale() {
    log "Upgrading Tailscale package to the latest available."
    pct exec "$CTID" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --only-upgrade tailscale
systemctl restart tailscaled
tailscale version
'
}

apt_dist_upgrade() {
    log "Running apt dist-upgrade inside the container (OS packages)."
    pct exec "$CTID" -- bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get -y -qq dist-upgrade
apt-get -y -qq autoremove
'
}

tailscale_up() {
    build_up_args
    if [[ -n "$TS_AUTHKEY" ]]; then
        log "Applying 'tailscale up' with auth key: ${UP_ARGS[*]}"
        pct exec "$CTID" -- tailscale up --authkey="$TS_AUTHKEY" "${UP_ARGS[@]}"
    elif pct exec "$CTID" -- tailscale status >/dev/null 2>&1; then
        # Already authenticated -- reconcile config without a key.
        log "Applying 'tailscale up' (already authenticated): ${UP_ARGS[*]}"
        pct exec "$CTID" -- tailscale up "${UP_ARGS[@]}"
    else
        warn "No TS_AUTHKEY and node not yet authenticated -- interactive login."
        warn "A login URL will print below; open it in a browser."
        pct exec "$CTID" -- tailscale up "${UP_ARGS[@]}" || true
    fi
}

print_status() {
    require_ct
    echo "=== Proxmox container $CTID ==="
    pct status "$CTID" || true
    if ct_running; then
        echo "=== tailscale version ==="
        pct exec "$CTID" -- tailscale version || true
        echo "=== tailscale status ==="
        pct exec "$CTID" -- tailscale status || true
    fi
}

post_notes() {
    cat <<EOF

------------------------------------------------------------------------
Mode: $MODE  |  Container $CTID ($HOSTNAME)

Advertised subnet routes : ${SUBNET_ROUTES}
Advertised exit node     : $( [[ "$ADVERTISE_EXIT_NODE" == "1" ]] && echo yes || echo no )

One-time in the Tailscale admin console (new nodes / new routes):
  https://login.tailscale.com/admin/machines
  Find "$HOSTNAME" -> Edit route settings: enable the subnet routes,
  tick "Use as exit node", and disable key expiry (it's infrastructure).

Verify:
  pct exec $CTID -- tailscale status
  pct exec $CTID -- tailscale netcheck
------------------------------------------------------------------------
EOF
}

# ---------------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------------

require_host

case "$MODE" in
    install)
        interactive_setup
        resolve_ctid
        resolve_template
        create_ct
        ensure_tun
        ensure_ct_running
        enable_forwarding
        install_tailscale
        enable_console_autologin
        tailscale_up
        post_notes
        ;;
    upgrade)
        require_ct
        ensure_ct_running
        upgrade_tailscale
        [[ "$APT_DIST_UPGRADE" == "1" ]] && apt_dist_upgrade
        enable_forwarding      # re-assert in case a package reset sysctl
        tailscale_up           # re-apply current route/exit config
        post_notes
        ;;
    reconfigure)
        require_ct
        ensure_ct_running
        enable_forwarding
        tailscale_up
        post_notes
        ;;
    status)
        print_status
        ;;
    *)
        die "Unknown MODE '$MODE'. Use: install | upgrade | reconfigure | status"
        ;;
esac
