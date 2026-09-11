# IKEv2 VPN Client

This app runs strongSwan in the Home Assistant host network namespace. Traffic
from Home Assistant that matches `remote_subnets` can therefore use the IPsec
tunnel. It requires network administration access for Linux XFRM policies and
uses host networking because a tunnel isolated inside the app would not help
Home Assistant itself. strongSwan remains root inside the container because
Home Assistant's app capability model does not expose the ownership and group
capabilities required by strongSwan's normal privilege transition.

## Before installing: identify the server

IKEv2/IPsec and OpenVPN are not interchangeable.

- `hwdsl2/ipsec-vpn-server` supports IKEv2. Use the **certificate** mode below.
- `kylemanna/openvpn` and other OpenVPN-only images do not support IKEv2. This
  app cannot connect to those servers; enable an IKEv2 server or use an
  OpenVPN client app instead.

Your server firewall must allow UDP 500 and UDP 4500.

## Install as a local app

1. Copy the `ikev2-client` directory to `/addons/ikev2-client` on Home
   Assistant. The Samba, SSH, or Studio Code Server app can be used to copy it.
2. In **Settings > Apps > App store**, open the menu and choose **Check for
   updates** (older Home Assistant versions call Apps "Add-ons").
3. Open **IKEv2 VPN Client** and select **Install**.

For a Git repository installation, publish this repository with a public HTTPS
URL, then add that URL as a custom app repository. The app is built directly
from its Dockerfile; no Home Assistant builder container is required.

## Recommended setup for `hwdsl2/ipsec-vpn-server`

The server generates a `.p12` file for each IKEv2 client. Create/export a
dedicated client such as `homeassistant`, then securely copy the resulting
`homeassistant.p12` into this app's configuration directory:

`/addon_configs/local_ikev2_client/homeassistant.p12`

The exact prefix may be a repository hash instead of `local`. Home Assistant
shows the app configuration directory under `/addon_configs`; use the directory
ending in `_ikev2_client`.

Set the app configuration:

```yaml
server: vpn.example.com
server_id: vpn.example.com
authentication: certificate
client_id: homeassistant
p12_file: homeassistant.p12
p12_password: "the import password shown by the server"
remote_subnets: 0.0.0.0/0
force_udp_encapsulation: false
reconnect_interval: 300
log_level: info
```

`server_id` must exactly match the IP address or DNS name in the server
certificate. `client_id` must exactly match the client name used to create the
bundle. If the server's helper did not print an import password, leave
`p12_password` empty.

The server project's Linux-client instructions may require adding
`authby=rsa-sha1` to the server's `ikev2-cp` connection and restarting IPsec.
Follow the instructions for the exact server version you installed. This is a
server compatibility setting; the tunnel encryption can still negotiate modern
IKE/ESP algorithms.

## Split tunnel or full tunnel

The default `remote_subnets: 0.0.0.0/0` requests a full IPv4 tunnel, matching
the default configuration of `hwdsl2/ipsec-vpn-server`. This can change the
public source IP used by Home Assistant and can affect remote access.

For a split tunnel, enter only networks that the server offers, separated by
commas:

```yaml
remote_subnets: 10.20.0.0/16,192.168.50.0/24
```

The server must advertise/permit the same traffic selectors. A client cannot
invent access to a remote LAN that the server does not route.

The app checks the tunnel every five minutes by default and attempts to bring
it back up when strongSwan no longer reports an installed child security
association. Set `reconnect_interval` between 10 and 3600 seconds if a
different check interval is needed.

## EAP-MSCHAPv2

For a server that authenticates clients with a username and password, place its
CA certificate (PEM or DER) in the app configuration directory and use:

```yaml
authentication: eap-mschapv2
username: homeassistant
password: "a strong password"
server_ca_file: server-ca.pem
```

Server certificate validation is mandatory; the app deliberately has no
"accept any certificate" setting.

## IKEv2 PSK

For an IKEv2 server explicitly configured for PSK authentication:

```yaml
authentication: psk
client_id: homeassistant
pre_shared_key: "a long random secret"
```

The PSK used by the IPsec/L2TP mode of `hwdsl2/ipsec-vpn-server` is not an
IKEv2 client credential for that server. Use its `.p12` IKEv2 bundle instead.

## Troubleshooting

- `AUTHENTICATION_FAILED`: verify the client ID, bundle password, or EAP/PSK
  credential. For `hwdsl2`, also check its Linux-client server setting.
- `no trusted RSA public key` or certificate errors: `server_id` does not match
  the server certificate, or the wrong CA/bundle was supplied.
- `no proposal chosen`: ask the server administrator for its algorithms and set
  `ike_proposals` and/or `esp_proposals`, for example
  `aes256-sha256-modp2048` and `aes128gcm16`.
- No response: confirm DNS, UDP 500/4500, cloud firewall rules, router firewall,
  and upstream NAT. Try `force_udp_encapsulation: true` behind restrictive NAT.
- Tunnel connects but a destination is unreachable: verify `remote_subnets`,
  server-side forwarding/routes, and that local and remote networks do not
  overlap.
- Home Assistant remote access changes after connection: use split tunneling
  instead of `0.0.0.0/0`, or ensure your VPN server correctly forwards full
  tunnel traffic.

Do not post app logs without reviewing them. strongSwan does not log configured
passwords, but logs can include public addresses, identities, and network names.
