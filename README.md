# escapace.tailscale

Installs and configures Tailscale on Red Hat-family hosts. It enables `tailscaled` at boot without starting it during image builds. Enrollment and subnet-router setup are separate from this role.

## Variables

- `tailscale_listen_port` defaults to `41641`. Use a fixed UDP port from 1 through 65535. The daemon and optional firewalld policy use the same port. In the [tailnet policy](https://tailscale.com/docs/reference/syntax/policy-file#randomizeclientport), omit `randomizeClientPort` or set it to `false`, and ensure no `nodeAttrs` rule applies `randomize-client-port` to these hosts. Enabling either form of randomization overrides this port, so the firewalld policy may not match the listener.
- `tailscale_peer_relay_port` defaults to `null` (disabled). Set a fixed UDP port from 1 through 65535, different from `tailscale_listen_port`, to enable a peer relay and its optional firewalld policy. This requires Tailscale 1.102.2 or newer.
- `tailscale_peer_relay_static_endpoints` defaults to `[]`, so the relay uses automatically discovered endpoints. Optionally provide a list of unique `IPv4:port` or `[IPv6]:port` strings to advertise additional external endpoints, such as load balancer addresses. Use literal IP addresses and ports from 1 through 65535. The list must be empty when the relay is disabled.
- `tailscale_host_access` defaults to `true`, allowing all Tailscale-authorized traffic to local host services. Set `false` or `[]` to omit this role's host-access policy, or use a list such as `["22/tcp", "53/udp"]` to limit that policy to the listed ports. Ports range from 1 through 65535. Other roles can allow additional ports regardless of this setting.
- `tailscale_accept_dns` defaults to `true`. The host accepts tailnet DNS settings and, when Knot Resolver is present, the role installs a MagicDNS forwarding policy. Set it to `false` to remove that policy. Knot Resolver retains ownership of `/etc/resolv.conf`.
- `tailscale_resolvers` defaults to Quad100's IPv4 and IPv6 addresses. Use one to four mappings such as `{address: "100.100.100.100"}`, with literal IPv4 or IPv6 addresses, to select different upstream DNS servers. This setting applies only to the Knot Resolver integration.
- `tailscale_accept_routes` defaults to `true`, so the host accepts routes advertised by other tailnet nodes. Tailscale's Linux default is `false`.
- `tailscale_limit_journal_logs` defaults to `true` and sets `LogLevelMax=notice` for `tailscaled.service`. Set it to `false` to restore the packaged unit's journal behavior. The filter can hide daemon messages written without an explicit severity, including error messages.
- `tailscale_package_state` defaults to `present`. Override the repository URL, distribution, key, and signature-check variables in `defaults/main.yaml` to use a different package repository.

## Daemon configuration

The role writes an `alpha0` JSON configuration file. It keeps netfilter mode `on`, stateful filtering enabled, and Tailscale's subnet-route SNAT enabled. It disables LAN access while using an exit node and checks for updates without automatically installing them. Enroll the node separately with `tailscale up`. The file is unlocked, so `tailscale set` can change runtime settings.

`TS_DEBUG_FIREWALL_MODE=nftables` selects Tailscale's nftables implementation. Tailscale documents this environment variable as temporary. `TS_NO_LOGS_NO_SUPPORT=true` disables Tailscale client telemetry and the support that depends on it. These settings do not change the tailnet's network-flow-log configuration.

## Optional integrations

When `tailscale_accept_dns` is `true` and both `/etc/knot-resolver/config.d` and `/etc/knot-resolver/config.yaml` exist, the role forwards DNS queries for names matching `machine.tailnet.ts.net` to the configured resolvers (Quad100 by default). The four-label pattern also matches names in other tailnets and unrelated names with the same form. It does not match short names, `ts.net`, or a tailnet's base domain, such as `tailnet.ts.net`.

The Knot policy uses `NO_CACHE`, `NO_EDNS`, and `NO_0X20` for these queries. The role compiles the Lua drop-in before installing it. It does not install Knot.

If `/etc/systemd/network` exists, the role tells systemd-networkd to leave `tailscale0` unmanaged.

If `/etc/firewalld/policies` exists, the role persistently binds `tailscale0` to its own `tailscale` zone. It manages a UDP policy for direct connections from any ingress zone, a host-access policy controlled by `tailscale_host_access`, and an `ANY` → `HOST` UDP policy when the peer relay is enabled. The zone blocks forwarding by default; see [Activating a subnet router](#activating-a-subnet-router) for how to allow it. The role does not change the `public` zone.

The role validates the complete firewalld configuration before reloading a running daemon. It does not start firewalld or networkd. Restarts and reloads of firewalld, networkd, Knot, and `tailscaled` apply only when each service is already running, and never in Ansible check mode.

Another role can allow access to its own service regardless of `tailscale_host_access`. Its policy adds to the ports allowed by this role, but is redundant when `tailscale_host_access` is `true`. For example, an application role can manage `/etc/firewalld/policies/app-tailnet.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<policy target="CONTINUE" priority="-1">
  <ingress-zone name="tailscale"/>
  <egress-zone name="HOST"/>
  <port port="8443" protocol="tcp"/>
  <port port="5353" protocol="udp"/>
</policy>
```

The application role needs to validate the complete firewalld configuration before reloading a running firewalld service. This policy allows traffic from `tailscale0` to the listed host ports. It does not allow forwarding or change the `public` zone.

## Activating a subnet router

Configure subnet routing at deployment time, when you know the destination networks, outgoing interfaces, and IP families. This role does not enable kernel forwarding or allow traffic between firewalld zones. The daemon configuration leaves `advertiseRoutes` unset, rather than setting it to `[]`, so a reload does not clear routes configured later with `tailscale set`. `tailscale_accept_routes` accepts other nodes' routes; it does not advertise this host's routes.

Your deployment automation manages the forwarding policy. For example, to route `192.0.2.0/24` through an interface in the `public` zone, it can create `/etc/firewalld/policies/site-tail-subnet.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<policy target="CONTINUE" priority="-1">
  <ingress-zone name="tailscale"/>
  <egress-zone name="public"/>
  <rule family="ipv4">
    <destination address="192.0.2.0/24"/>
    <accept/>
  </rule>
</policy>
```

Replace `192.0.2.0/24` in both the policy and the command below with a real, approved subnet. The policy allows all protocols from `tailscale0` to that destination; your deployment can restrict the ports further. It does not allow forwarding to other destinations or grant local host access. The earlier `tailscale` → `HOST` policy allows local host access only.

In your deployment automation:

1. Confirm that each subnet is reached through the intended non-Tailscale interface. Install a firewalld policy limited to that destination. Ensure firewalld is running, validate the complete configuration with `firewall-offline-cmd --system-config=/etc/firewalld --check-config`, and reload it before advertising routes.
2. Enable kernel forwarding only for the IP families you will advertise. If an IPv6 uplink uses router advertisements, keep accepting them after enabling forwarding. Changing `ip_forward` can reset other IPv4 settings; reapply any that your deployment requires.
3. After enrollment, advertise the approved subnets with `tailscale set --advertise-routes=192.0.2.0/24`. Use a comma-separated list for multiple subnets. Approve the routes in the tailnet (or use `autoApprovers`) and grant peer access separately.

Leave Tailscale's subnet-route SNAT enabled unless your deployment provides return routes. Do not add blanket firewalld masquerading. Before removing a subnet's firewalld policy, stop advertising that subnet. Disable kernel forwarding only if no other workload uses it.

## Activating a peer relay

A [peer relay](https://tailscale.com/docs/features/peer-relay) carries traffic between tailnet devices when a direct connection is unavailable. Unlike a subnet router, it needs neither kernel forwarding nor advertised subnet routes. This role leaves it disabled by default.

To enable a relay, set `tailscale_peer_relay_port` on the chosen host. Static endpoints are not required: the default `[]` lets Tailscale discover endpoints automatically.

```yaml
roles:
  - role: escapace.tailscale
    vars:
      tailscale_peer_relay_port: 40000
```

If Tailscale cannot discover an endpoint exposed by port forwarding or a load balancer, add it to `tailscale_peer_relay_static_endpoints`. For example, if a public endpoint forwards `203.0.113.10:45000` to local `40000/udp`, add this variable:

```yaml
tailscale_peer_relay_static_endpoints:
  - '203.0.113.10:45000'
```

Replace `203.0.113.10` with a real address. Static endpoints supplement automatic discovery; their ports can differ from the local listening port.

The role stores the relay settings in the daemon's JSON configuration file so they survive restarts and configuration reloads. Tailscale 1.102.2 implements these fields, but they are not listed in its published [`alpha0` configuration reference](https://tailscale.com/docs/reference/tailscaled/tailscaled-config-file). Test package upgrades before deploying them to relay hosts. Values set only with `tailscale set` are replaced by the file's values on the next restart or configuration reload.

With the optional firewalld integration, the role allows traffic to the local UDP relay port from every ingress zone, not just `tailscale0`. It removes that policy when you disable the relay. Ensure firewalld is running and the port is reachable through upstream firewalls or port forwarding. In the port-forwarding example, firewalld allows local `40000/udp`, while the public endpoint forwards `45000/udp` to it.

A tailnet admin also needs to authorize relay use. For example, add this grant to the existing `grants` list:

```json
{
  "src": ["tag:restricted-nodes"],
  "dst": ["tag:peer-relays"],
  "app": { "tailscale.com/cap/relay": [] }
}
```

Here `src` identifies devices that need a relay, and `dst` identifies relay hosts. Separate tailnet rules control access between the communicating devices; permission to use a relay does not grant that access. Check `tailscale status` on a participating device for a `peer-relay` connection when a direct connection is unavailable.

To disable the relay, set `tailscale_peer_relay_port` to `null` and `tailscale_peer_relay_static_endpoints` to `[]` in your deployment configuration. Rerun the role, then remove the relay's tailnet grant and any upstream port mapping.
