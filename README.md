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

Paste this into the Proxmox **host** shell (as root). It downloads the latest
script from this repo and runs `install`. Edit the variables on the first lines
first. The repo is **private**, so the fetch needs a GitHub token with `repo`
scope (create one at <https://github.com/settings/tokens>):

```bash
# --- edit these ---
export GITHUB_TOKEN="ghp_your_token_here"        # token with 'repo' scope (private repo)
export SUBNET_ROUTES="192.168.1.0/24"             # your LAN(s), comma-separated
export TS_AUTHKEY="tskey-XXXX"                    # https://login.tailscale.com/admin/settings/keys
export CTID="150"                                 # unused container ID
# optional: export IP_CONFIG="192.168.1.50/24"; export GATEWAY="192.168.1.1"
# -------------------

curl -fsSL \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.v3.raw" \
  "https://api.github.com/repos/dpnguyen01/proxmox-tailscale-gateway/contents/deploy-tailscale-lxc.sh?ref=main" \
  -o /root/deploy-tailscale-lxc.sh
chmod +x /root/deploy-tailscale-lxc.sh
/root/deploy-tailscale-lxc.sh install
```

Later, to upgrade or re-point routes, re-fetch (or just reuse the saved copy):

```bash
APT_DIST_UPGRADE=1 /root/deploy-tailscale-lxc.sh upgrade
SUBNET_ROUTES="10.0.0.0/24,192.168.1.0/24" /root/deploy-tailscale-lxc.sh reconfigure
/root/deploy-tailscale-lxc.sh status
```

> If you later make the repo **public**, the fetch simplifies to a plain
> `curl -fsSL https://raw.githubusercontent.com/dpnguyen01/proxmox-tailscale-gateway/main/deploy-tailscale-lxc.sh -o /root/deploy-tailscale-lxc.sh`
> with no token.

Then, one-time in the admin console
(<https://login.tailscale.com/admin/machines>): enable the subnet routes, tick
**Use as exit node**, and disable key expiry on the node.

See [`ansible/README.md`](ansible/README.md) for the Ansible path.

## Modes (bash script)

The script is re-runnable and takes a mode as its first argument (default
`install`):

| Mode | What it does |
|------|--------------|
| `install` | Create the container if absent, map TUN, install Tailscale, enable forwarding, bring it up. Idempotent. |
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

> **Secrets:** never commit a real `TS_AUTHKEY` or Proxmox API token. The
> `.gitignore` excludes common secret files; use `ansible-vault` for the
> Ansible path.
