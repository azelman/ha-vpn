# Home Assistant IKEv2 VPN client

This repository contains a Home Assistant app (add-on) that connects the Home
Assistant host to a remote IKEv2/IPsec VPN using strongSwan.

The app supports:

- certificate authentication from a PKCS#12 (`.p12`) bundle (the default and
  the correct mode for `hwdsl2/ipsec-vpn-server`);
- EAP-MSCHAPv2 username/password authentication; and
- IKEv2 pre-shared-key authentication.

See [the app documentation](ikev2-client/DOCS.md) for installation and setup.

> [!IMPORTANT]
> IKEv2/IPsec and OpenVPN are different protocols. An OpenVPN-only server such
> as `kylemanna/openvpn` will not work with this app. The popular
> `hwdsl2/ipsec-vpn-server` image does support IKEv2.
