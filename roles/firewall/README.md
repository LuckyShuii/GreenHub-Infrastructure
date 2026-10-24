# `firewall` role

Manages the host firewall with UFW. Incoming traffic is denied by default; outgoing
traffic is allowed. The role allows HTTPS (443/tcp), OpenVPN (1194/udp), and HTTP
(80/tcp, enabled by default for Caddy redirects and ACME). SSH (22/tcp) is allowed
only on `firewall_vpn_interface` (`tun0` by default); everywhere else it falls under the
default deny, so an external scan reports it as `filtered`.

## VPN-only SSH and the lockout guard

`firewall_ssh_vpn_only` (default `true`) controls whether SSH is reachable from the
Internet:

- `true`: SSH only through the VPN. The role **fails before touching UFW** if
  `firewall_vpn_interface` does not exist on the host, so it cannot lock out the admins
  (and its own next run).
- `false`: SSH is also allowed from the Internet. Bootstrap only, until OpenVPN
  (SCRUM-58) is deployed. Production sets this today, because Ansible still connects
  over the public IP.

Switching to `true` removes the public SSH rule on the next run. Do it once the VPN is
up **and** the inventory's `ansible_host` points at the VPN address. Override
`firewall_vpn_interface` if OpenVPN uses a different interface name.

## Docker

Docker writes its own iptables rules and bypasses UFW for published ports. The
production Compose files therefore publish only on loopback (`app_stack_gateway_publish`,
`monitoring_grafana_publish`); every other service uses the internal Docker network.
Caddy runs natively on the host and is the only service listening on 80/443.

## Testing and switching to VPN-only

See [`docs/firewall.md`](../../docs/firewall.md): how to test the role, the step-by-step
checklist to switch SSH to VPN-only once OpenVPN is deployed, and how to recover from a
lockout.
