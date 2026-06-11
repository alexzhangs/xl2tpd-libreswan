# xl2tpd-libreswan

L2TP/IPsec (PSK) VPN server in Docker: libreswan (IKEv1 PSK) + xl2tpd + pppd.

This image supersedes the host installer
[aws-ec2-xl2tpd](https://github.com/alexzhangs/aws-ec2-xl2tpd) — the same
way [shadowsocks-libev-v2ray](https://github.com/alexzhangs/shadowsocks-libev-v2ray)
superseded [aws-ec2-shadowsocks-libev](https://github.com/alexzhangs/aws-ec2-shadowsocks-libev).
The installer targeted Amazon Linux / Amazon Linux 2, whose openswan/xl2tpd
packages came from EPEL; Amazon Linux 2 reaches end of support on
2026-06-30 and Amazon Linux 2023 ships neither package (no EPEL support,
and they are not in [SPAL](https://docs.aws.amazon.com/linux/al2023/ug/spal.html)
either). The container runs on AL2, AL2023, and any Linux host with Docker.

## Usage

```sh
docker run -d --name l2tpd --restart=always \
  --privileged --network=host \
  -v /lib/modules:/lib/modules:ro \
  -e IPSEC_PSK=your_psk \
  -e L2TP_USERNAME=your_user \
  -e L2TP_PASSWORD=your_password \
  alexzhangs/xl2tpd-libreswan
```

Why `--privileged --network=host -v /lib/modules`:

* pppd needs `/dev/ppp` — the entrypoint modprobes `ppp_generic` from the
  host's kernel modules and creates the device node.
* IKE/NAT-T must terminate on the host's UDP 500/4500 (ESP cannot be
  port-mapped), and the MASQUERADE/FORWARD rules for the client pool live
  in the host netns.
* `net.ipv4.ip_forward` & co. are written by the entrypoint.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `IPSEC_PSK` | random, printed once | IPsec Pre-Shared Key |
| `L2TP_USERNAME` | none — no user created | L2TP/PPP (CHAP) username |
| `L2TP_PASSWORD` | random, printed once (if username set) | L2TP/PPP (CHAP) password |
| `PRIMARY_DNS` | `8.8.8.8` | DNS pushed to clients |
| `SECONDARY_DNS` | `8.8.4.4` | DNS pushed to clients |
| `L2TP_VIRTUAL_IP` | `192.168.42.1` | Server-side PPP address |
| `L2TP_DHCP_BEGIN` | `192.168.42.10` | Client pool start |
| `L2TP_DHCP_END` | `192.168.42.250` | Client pool end |
| `L2TP_DHCP_CIDR` | `192.168.42.0/24` | Client pool CIDR (must cover the above) |
| `NAT_INTERFACE` | auto-detected from the default route | Outbound interface for NAT (`eth0` on AL2, `ens5` on AL2023) |
| `LEFT_IP` | first global IPv4 on `NAT_INTERFACE` | Local IKE endpoint address (the EC2 private IP) |

### Manage L2TP users at runtime

[chap-manager](https://github.com/alexzhangs/chap-manager) is bundled in
the image:

```sh
docker exec l2tpd chap-manager.sh -a add -u user2 -p pass2
docker exec l2tpd chap-manager.sh -a del -u user2
docker exec l2tpd chap-manager.sh -a get -u user2
```

Persist users across container re-creation with a volume: `-v l2tp-ppp:/etc/ppp`.

### EC2 security group

| Type | Protocol | Port range | Source |
|---|---|---|---|
| Custom UDP | UDP | 500 | 0.0.0.0/0 |
| Custom UDP | UDP | 4500 | 0.0.0.0/0 |

NOTE: Don't list the UDP port `1701` in the inbound rules. It should
never be opened to the outside — L2TP must only be reachable through the
IPsec tunnel.

### Build the image yourself

```sh
git clone https://github.com/alexzhangs/xl2tpd-libreswan
docker build -t alexzhangs/xl2tpd-libreswan xl2tpd-libreswan
```

## Clients

The image serves the native L2TP/IPsec (PSK) clients of macOS, iOS,
Windows, and Android. The IKE/ESP proposals are strong-only (AES-256 +
SHA2-256 + MODP2048); PPP auth requires MS-CHAPv2.

## Troubleshooting

1. Check the server logs

    ```sh
    docker logs -f l2tpd
    ```

1. Check the IPsec status

    ```sh
    docker exec l2tpd ipsec status
    docker exec l2tpd ipsec trafficstatus
    ```

1. Enable xl2tpd debugging

    Uncomment the `debug ...` lines in `conf/xl2tpd.conf`, rebuild or mount
    the config, and restart the container.

1. Check the client logs (macOS)

    Check the logs in application `Console`: `Log Reports -> ppp.log`. Or
    in the command line:

    ```sh
    tail -f /var/log/ppp.log
    ```

## Reference

* [xl2tpd](https://github.com/xelerance/xl2tpd) at Github
* [libreswan](https://libreswan.org/)
* [L2tp ipsec configuration using openswan and xl2tpd](https://github.com/xelerance/Openswan/wiki/L2tp-ipsec-configuration-using-openswan-and-xl2tpd)
* https://serverfault.com/questions/451381/which-ports-for-ipsec-lt2p
* [aws-cfn-vpn](https://github.com/alexzhangs/aws-cfn-vpn) — CloudFormation
  stack that deploys this image (`EnableL2TP=1`)
* [aws-ec2-xl2tpd](https://github.com/alexzhangs/aws-ec2-xl2tpd) — the
  superseded Amazon Linux host installer
