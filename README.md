# proxmox-tailscale-gateway

Deploy a Proxmox LXC running [Tailscale](https://tailscale.com) as an
**exit node** and **subnet router**. Two interchangeable paths — pick one:

| Path | When to use it | File |
|------|----------------|------|
| **Bash** | A one-off / single gateway. Run once on the Proxmox host. | [`deploy-tailscale-lxc.sh`](deploy-tailscale-lxc.sh) |
| **Ansible** | Several gateways, rebuilds, or part of a wider IaC setup. | [`ansible/`](ansible/) |

Both do the same thing:

- Create an **unprivileged** Debian LXC (tracks the **latest** Debian standard
  template automatically).
- Map `/dev/net/tun` into the container — the step an unprivileged LXC needs
  before `tailscaled` will run.
- Enable IPv4 + IPv6 forwarding (required for exit-node / subnet routing).
- Install Tailscale and bring it up advertising your subnet routes and exit node.

## Quick start (bash)

On the Proxmox host, as root:

```bash
SUBNET_ROUTES="192.168.1.0/24" TS_AUTHKEY="tskey-XXXX" \
  ./deploy-tailscale-lxc.sh
```

### Run directly from the Proxmox host shell (no manual copy)

Paste this into the Proxmox **host** shell (as root) — the standard Proxmox
helper-script one-liner. It downloads and runs the script; with **no variables
set**, `install` drops into an interactive **setup screen** that prompts for
each setting (CTID, hostname, storage, network, subnet routes, exit-node
toggle, auth key — hidden input), shows a summary, and asks you to confirm
before building:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dpnguyen01/proxmox-tailscale-gateway/main/deploy-tailscale-lxc.sh)"
```

This form keeps your terminal attached, so the setup screen can prompt. (`curl
… | bash` would starve the prompts of stdin — use the `bash -c "$(…)"` form.)
To pass a non-default mode, append it after a `_` placeholder (which becomes
`$0`), e.g. `… )" _ upgrade`.

Prefer to pre-fill some or all answers? Set them as env vars first — any value
you provide is **not** prompted for; only the rest are asked:

```bash
SUBNET_ROUTES="192.168.1.0/24" TS_AUTHKEY="tskey-XXXX" CTID="150" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/dpnguyen01/proxmox-tailscale-gateway/main/deploy-tailscale-lxc.sh)"
```

For fully unattended runs (CI, or no terminal), set `NONINTERACTIVE=1` (the
script also auto-skips the screen when there is no TTY) and provide everything
via env vars:

```bash
NONINTERACTIVE=1 SUBNET_ROUTES="192.168.1.0/24" TS_AUTHKEY="tskey-XXXX" CTID="150" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/dpnguyen01/proxmox-tailscale-gateway/main/deploy-tailscale-lxc.sh)" _ install
```

Or fetch-then-run if you'd rather keep a local copy to review and reuse:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/dpnguyen01/proxmox-tailscale-gateway/main/deploy-tailscale-lxc.sh \
  -o /root/deploy-tailscale-lxc.sh
chmod +x /root/deploy-tailscale-lxc.sh
/root/deploy-tailscale-lxc.sh install
```

Later, to upgrade or re-point routes, reuse the saved copy (these modes are
always non-interactive):

```bash
APT_DIST_UPGRADE=1 /root/deploy-tailscale-lxc.sh upgrade
SUBNET_ROUTES="10.0.0.0/24,192.168.1.0/24" /root/deploy-tailscale-lxc.sh reconfigure
/root/deploy-tailscale-lxc.sh status
```

Then, one-time in the admin console
(<https://login.tailscale.com/admin/machines>): enable the subnet routes, tick
**Use as exit node**, and disable key expiry on the node.

See [`ansible/README.md`](ansible/README.md) for the Ansible path.

## Console access & SSH

- **Proxmox console** opens a **root shell with no login prompt** — the install
  flow configures autologin on the container's console tty, so the web-UI
  Console button, `pct console <ctid>`, and `pct enter <ctid>` all drop
  straight to root. This goes through the Proxmox host, not the network, so it
  works regardless of Tailscale. Disable with `CONSOLE_AUTOLOGIN=0`.
  (Anyone with Proxmox access can already `pct enter` as root, so autologin
  does not widen that.)
- **Tailscale SSH is OFF by default.** The container has no SSH entry path
  unless you ask for one. To enable Tailscale SSH (network login over the
  tailnet, governed by your ACLs), pass `TS_EXTRA_ARGS="--ssh"`.

## Modes (bash script)

The script is re-runnable and takes a mode as its first argument (default
`install`):

| Mode | What it does |
|------|--------------|
| `install` | Create the container if absent, map TUN, install Tailscale, enable forwarding, bring it up. Idempotent. On a TTY with values unset, prompts via an interactive setup screen (skip with `NONINTERACTIVE=1`). |
| `upgrade` | Upgrade the Tailscale package to latest, restart it, re-apply forwarding + current route/exit config. Add `APT_DIST_UPGRADE=1` to also `apt dist-upgrade` the OS. Does **not** recreate the container. |
| `reconfigure` | Re-apply `tailscale up` with the current `SUBNET_ROUTES` / `ADVERTISE_EXIT_NODE` / `TS_EXTRA_ARGS`. Use after changing routes or toggling the exit node. No package changes. |
| `status` | Print container + Tailscale status (read-only). |

```bash
./deploy-tailscale-lxc.sh install                         # first deploy
APT_DIST_UPGRADE=1 ./deploy-tailscale-lxc.sh upgrade       # update TS + OS
SUBNET_ROUTES="10.0.0.0/24" ./deploy-tailscale-lxc.sh reconfigure
./deploy-tailscale-lxc.sh status
```

**Debian major-version upgrades (12 → 13) are intentionally not automated** —
in-place LXC release upgrades are risky. The clean path is to `install` a fresh
container on a new `CTID` (it auto-selects the latest template) and retire the
old one. `upgrade` only moves packages within the installed release.

## Configuration

The bash script reads env-var overrides (`CTID`, `STORAGE`, `IP_CONFIG`,
`GATEWAY`, `SUBNET_ROUTES`, `ADVERTISE_EXIT_NODE`, `TS_AUTHKEY`, …) — see the
`CONFIG` block at the top of the script. Ansible reads `ansible/group_vars/all.yml`.

Leave `CTID` unset and the script auto-picks the **next free container ID**
(≥ 100, via `pvesh get /cluster/nextid`); the interactive screen shows the
picked ID as its default.

### Resource sizing (defaults + why)

A Tailscale exit-node / subnet-router is a **light** workload — userspace
WireGuard, no GUI or database. The defaults suit a typical home uplink:

| Setting | Default | When to raise it |
|---------|---------|------------------|
| **Cores** | 1 | 2 only for >~500 Mbps throughput or a busy exit node serving many clients. One core saturates most home uplinks. |
| **Memory** | 512 MB | 256 MB is the floor; `tailscaled` idles ~50–100 MB, 512 leaves headroom for apt + bursts. |
| **Swap** | 512 MB | A small OOM-killer safety net; matching RAM is plenty. Not performance-critical. |
| **Disk** | 4 GB | Debian + Tailscale is ~2 GB; 4 GB leaves room for logs and upgrades. |

> **Secrets:** never commit a real `TS_AUTHKEY` or Proxmox API token. The
> `.gitignore` excludes common secret files; use `ansible-vault` for the
> Ansible path.
