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

Then, one-time in the admin console
(<https://login.tailscale.com/admin/machines>): enable the subnet routes, tick
**Use as exit node**, and disable key expiry on the node.

See [`ansible/README.md`](ansible/README.md) for the Ansible path.

## Configuration

The bash script reads env-var overrides (`CTID`, `STORAGE`, `IP_CONFIG`,
`GATEWAY`, `SUBNET_ROUTES`, `ADVERTISE_EXIT_NODE`, `TS_AUTHKEY`, …) — see the
`CONFIG` block at the top of the script. Ansible reads `ansible/group_vars/all.yml`.

> **Secrets:** never commit a real `TS_AUTHKEY` or Proxmox API token. The
> `.gitignore` excludes common secret files; use `ansible-vault` for the
> Ansible path.
