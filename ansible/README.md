# Proxmox LXC + Tailscale (exit node + subnet router) — Ansible

Provisions a Proxmox LXC and configures Tailscale inside it as an **exit node**
and **subnet router**. Tracks the **latest Debian** standard template by default.

## Layout

```
ansible/
├── deploy-tailscale-lxc.yml   # the playbook (2 plays)
├── inventory.ini              # your Proxmox host
└── group_vars/all.yml         # all tunables (edit this)
```

## Prerequisites (on the Ansible control node)

```bash
ansible-galaxy collection install community.general
pip install proxmoxer requests        # required by the proxmox* modules
```

A Proxmox **API token**: Datacenter → Permissions → API Tokens. Put its ID and
secret in `group_vars/all.yml` (ideally ansible-vault encrypted).

The `proxmox` host in `inventory.ini` also needs **SSH access** (or be the
control node itself), because resolving the latest template (`pveam`) and
patching the TUN device into the container config happen on the host directly —
the API cannot set raw `lxc.*` options or run `pveam`.

## Configure

Edit `group_vars/all.yml`:

- **Proxmox**: `pve_node`, `pve_api_host`, token ID/secret, `template_storage`,
  `ct_storage`, `ct_bridge`.
- **Template**: leave `template_name: ""` to auto-pick the newest
  `debian-*-standard` template. Pin a specific one only if you want to.
- **Tailscale**: `subnet_routes` (your LAN(s)), `advertise_exit_node`, and a
  reusable `ts_authkey` from <https://login.tailscale.com/admin/settings/keys>.

Protect secrets:

```bash
ansible-vault encrypt group_vars/all.yml      # or just the secret vars
```

## Run

```bash
ansible-playbook -i inventory.ini deploy-tailscale-lxc.yml --ask-vault-pass
```

## The container-reachability detail

Play 1 creates the CT on the host. Play 2 configures Tailscale **inside** it and
needs to reach it. Two ways:

1. **Static IP (simplest):** set `ct_ip_spec: "ip=192.168.1.50/24,gw=192.168.1.1"`
   and `ct_ssh_host: "192.168.1.50"`. Play 2 SSHes straight in. (The Debian
   standard template permits root SSH; drop a key in or set a password first if
   your image differs.)

2. **DHCP:** leave `ct_ssh_host: ""`. Play 2 is skipped. Finish from the host
   with one command (no SSH needed — uses `pct exec`):

   ```bash
   CTID=150
   pct exec $CTID -- bash -c '
     echo -e "net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1" \
       > /etc/sysctl.d/99-tailscale.conf && sysctl --system
     curl -fsSL https://tailscale.com/install.sh | sh
     systemctl enable --now tailscaled'
   pct exec $CTID -- tailscale up \
     --authkey=tskey-XXXX \
     --advertise-routes=192.168.1.0/24 \
     --advertise-exit-node --ssh
   ```

## After it runs (one-time, in the admin console)

<https://login.tailscale.com/admin/machines> → find `tailscale-gw`:

- **Edit route settings** → enable the subnet routes and tick **Use as exit node**.
- **Disable key expiry** on the node (it's infrastructure).

If you advertise private ranges and still can't reach them, also check that the
subnet route isn't masked by Tailscale's `--accept-routes` behaviour on the
*client* side and that the LAN's own gateway knows how to return traffic (or
that masquerading is on — Tailscale masquerades advertised subnet traffic by
default).

## Why these specific settings

- **`lxc.mount.entry: /dev/net/tun`** + **`lxc.cgroup2.devices.allow: c 10:200 rwm`** —
  Tailscale's `tailscaled` needs the TUN device; an unprivileged LXC doesn't get
  it unless bind-mounted and allowed. `10:200` is TUN's major:minor.
- **`features: nesting=1`** — lets the container's systemd manage `tailscaled`
  cleanly.
- **IP forwarding** (`net.ipv4.ip_forward`, `net.ipv6.conf.all.forwarding`) — an
  exit node / subnet router forwards packets between interfaces; off by default.

## Verify

```bash
pct exec 150 -- tailscale status
pct exec 150 -- tailscale netcheck
```

There's also a standalone bash version at
`../deploy-tailscale-lxc.sh` (run on the Proxmox host) if you'd rather not use
Ansible for a one-off.
