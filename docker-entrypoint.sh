#!/bin/bash

# Entrypoint for the xl2tpd-libreswan Docker image: render the libreswan +
# xl2tpd + pppd configs from environment variables, prepare the host-side
# networking (sysctl, NAT, /dev/ppp), then run pluto and xl2tpd.
#
# Environment variables:
#   IPSEC_PSK         IPsec Pre-Shared Key. Generated and printed if unset.
#   L2TP_USERNAME     L2TP/PPP (CHAP) username. If unset, NO user is created.
#   L2TP_PASSWORD     L2TP/PPP (CHAP) password. Generated and printed if
#                     L2TP_USERNAME is set and this is not.
#   PRIMARY_DNS       DNS pushed to clients, default 8.8.8.8.
#   SECONDARY_DNS     DNS pushed to clients, default 8.8.4.4.
#   L2TP_VIRTUAL_IP   Server-side PPP address, default 192.168.42.1.
#   L2TP_DHCP_BEGIN   Client pool start, default 192.168.42.10.
#   L2TP_DHCP_END     Client pool end, default 192.168.42.250.
#   L2TP_DHCP_CIDR    Client pool CIDR (must cover the above), default
#                     192.168.42.0/24.
#   NAT_INTERFACE     Outbound interface for the MASQUERADE rule. Default:
#                     auto-detected from the default route (eth0 on AL2,
#                     ens5 on AL2023).
#   LEFT_IP           Local IKE endpoint address. Default: the first global
#                     IPv4 address on NAT_INTERFACE (the EC2 private IP).
#
# The container expects: --privileged --network=host -v /lib/modules:/lib/modules:ro
# (pppd needs /dev/ppp via modprobe+mknod; IKE/NAT-T must terminate on the
# host's UDP 500/4500; the NAT rule and ip_forward live in the host netns).

# Exit on any error
set -o pipefail -e

WORK_DIR=$(cd "$(dirname "$0")"; pwd)

[[ -z $PRIMARY_DNS ]] && PRIMARY_DNS="8.8.8.8"
[[ -z $SECONDARY_DNS ]] && SECONDARY_DNS="8.8.4.4"
[[ -z $L2TP_VIRTUAL_IP ]] && L2TP_VIRTUAL_IP="192.168.42.1"
[[ -z $L2TP_DHCP_BEGIN ]] && L2TP_DHCP_BEGIN="192.168.42.10"
[[ -z $L2TP_DHCP_END ]] && L2TP_DHCP_END="192.168.42.250"
[[ -z $L2TP_DHCP_CIDR ]] && L2TP_DHCP_CIDR="192.168.42.0/24"

if [[ -z $IPSEC_PSK ]]; then
    # No PSK supplied: generate a strong random one instead of falling back
    # to a well-known default (anyone could connect with it).
    IPSEC_PSK=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf '\n[!] No IPSEC_PSK supplied; generated a random pre-shared key:\n' >&2
    printf '      %s\n' "$IPSEC_PSK" >&2
    printf '    Save it now and configure it on every client.\n\n' >&2
fi

if [[ -n $L2TP_USERNAME && -z $L2TP_PASSWORD ]]; then
    L2TP_PASSWORD=$(openssl rand -hex 12 2>/dev/null || head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
    printf '\n[!] No L2TP_PASSWORD supplied; generated a random password for %s:\n' "$L2TP_USERNAME" >&2
    printf '      %s\n' "$L2TP_PASSWORD" >&2
    printf '    Save it now and configure it on the clients.\n\n' >&2
fi

# NAT interface and the IKE endpoint address — needed before rendering
# ipsec.conf. eth0 on AL2, ens5 on AL2023.
if [[ -z $NAT_INTERFACE ]]; then
    NAT_INTERFACE=$(ip -4 route show default | awk '{for (i=1; i<NF; i++) if ($i == "dev") {print $(i+1); exit}}')
fi
echo "using NAT interface: ${NAT_INTERFACE:?failed to detect the default-route interface; set NAT_INTERFACE}"
if [[ -z $LEFT_IP ]]; then
    LEFT_IP=$(ip -4 -o addr show dev "$NAT_INTERFACE" scope global | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}')
fi
echo "using IKE endpoint address: ${LEFT_IP:?failed to detect an IPv4 address on $NAT_INTERFACE; set LEFT_IP}"

# ipsec.conf
echo 'installing /etc/ipsec.conf ...'
/bin/cp -a "$WORK_DIR"/conf/ipsec.conf /etc/ipsec.conf
sed -i "s|<L2TP_DHCP_CIDR>|$L2TP_DHCP_CIDR|" /etc/ipsec.conf
sed -i "s/<LEFT_IP>/$LEFT_IP/" /etc/ipsec.conf

# ipsec.secrets
# Written with printf rather than sed so the PSK can't break the
# substitution (it may contain arbitrary characters).
echo 'installing /etc/ipsec.secrets ...'
printf '%%any %%any : PSK "%s"\n' "$IPSEC_PSK" > /etc/ipsec.secrets
chmod 600 /etc/ipsec.secrets

# xl2tpd.conf
echo 'installing /etc/xl2tpd/xl2tpd.conf ...'
mkdir -p /etc/xl2tpd
/bin/cp -a "$WORK_DIR"/conf/xl2tpd.conf /etc/xl2tpd/xl2tpd.conf
sed -i "s/<L2TP_VIRTUAL_IP>/$L2TP_VIRTUAL_IP/" /etc/xl2tpd/xl2tpd.conf
sed -i "s/<L2TP_DHCP_BEGIN>/$L2TP_DHCP_BEGIN/" /etc/xl2tpd/xl2tpd.conf
sed -i "s/<L2TP_DHCP_END>/$L2TP_DHCP_END/" /etc/xl2tpd/xl2tpd.conf

# options.xl2tpd
echo 'installing /etc/ppp/options.xl2tpd ...'
/bin/cp -a "$WORK_DIR"/conf/options.xl2tpd /etc/ppp/options.xl2tpd
sed -i "s/<PRIMARY_DNS>/$PRIMARY_DNS/" /etc/ppp/options.xl2tpd
sed -i "s/<SECONDARY_DNS>/$SECONDARY_DNS/" /etc/ppp/options.xl2tpd

# chap-secrets
# Append-if-absent so users added at runtime (chap-manager.sh via docker
# exec, persisted with a /etc/ppp volume) survive a container restart.
echo 'installing /etc/ppp/chap-secrets ...'
if [[ ! -e /etc/ppp/chap-secrets ]]; then
    /bin/cp -a "$WORK_DIR"/conf/chap-secrets /etc/ppp/chap-secrets
fi
chmod 600 /etc/ppp/chap-secrets
if [[ -n $L2TP_USERNAME ]]; then
    # Same unquoted tab-separated format as chap-manager.sh, so the entry
    # stays manageable with it (docker exec <container> chap-manager.sh ...).
    if ! awk -v u="$L2TP_USERNAME" '$1 == u {found=1} END {exit !found}' /etc/ppp/chap-secrets; then
        printf '%s\t*\t%s\t*\n' "$L2TP_USERNAME" "$L2TP_PASSWORD" >> /etc/ppp/chap-secrets
    fi
else
    echo '[!] L2TP_USERNAME is not set; no CHAP user was created.' >&2
    echo '    Add users with: docker exec <container> chap-manager.sh -a add -u <user> -p <password>' >&2
fi

# sysctl
# Interface-specific keys use the detected NAT interface. Failures are
# warnings: with --network=host these keys are host-wide and may be
# read-only without --privileged.
echo 'updating sysctl settings ...'
function sysctl-try () {
    # Usage: sysctl-try <key>=<value>
    sysctl -w "$1" || echo "[!] failed to set $1 — run the container with --privileged" >&2
}
sysctl-try 'net.ipv4.ip_forward=1'
sysctl-try 'net.ipv4.conf.all.accept_redirects=0'
sysctl-try 'net.ipv4.conf.all.send_redirects=0'
sysctl-try 'net.ipv4.conf.default.accept_redirects=0'
sysctl-try 'net.ipv4.conf.default.send_redirects=0'
sysctl-try "net.ipv4.conf.$NAT_INTERFACE.accept_redirects=0"
sysctl-try "net.ipv4.conf.$NAT_INTERFACE.send_redirects=0"

# /dev/ppp
# pppd needs the ppp_generic kernel module and the /dev/ppp device node.
echo 'preparing /dev/ppp ...'
modprobe ppp_generic 2>/dev/null || true
modprobe ppp_mppe 2>/dev/null || true
if [[ ! -c /dev/ppp ]]; then
    mknod /dev/ppp c 108 0 2>/dev/null || true
fi
if [[ ! -c /dev/ppp ]]; then
    echo '[!] /dev/ppp is missing and could not be created; PPP sessions WILL fail.' >&2
    echo '    Run with: --privileged -v /lib/modules:/lib/modules:ro' >&2
fi

# iptables
# MASQUERADE the client pool out of the NAT interface, and explicitly
# ACCEPT its forwarded traffic — Docker sets the FORWARD chain policy to
# DROP on hosts where it manages iptables, which would otherwise silently
# black-hole the VPN clients.
echo 'updating iptables rules ...'
if ! iptables -t nat -C POSTROUTING -s "$L2TP_DHCP_CIDR" -o "$NAT_INTERFACE" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$L2TP_DHCP_CIDR" -o "$NAT_INTERFACE" -j MASQUERADE
fi
if ! iptables -C FORWARD -s "$L2TP_DHCP_CIDR" -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -s "$L2TP_DHCP_CIDR" -j ACCEPT
fi
if ! iptables -C FORWARD -d "$L2TP_DHCP_CIDR" -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -d "$L2TP_DHCP_CIDR" -j ACCEPT
fi
# Clamp TCP MSS to the path MTU: the ESP+L2TP+PPP overhead shrinks the
# effective MTU and some networks drop the ICMP needed for PMTU discovery,
# which shows up as "connects fine but some sites hang".
if ! iptables -t mangle -C FORWARD -s "$L2TP_DHCP_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
    iptables -t mangle -A FORWARD -s "$L2TP_DHCP_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu \
        || echo '[!] failed to add the TCP MSS clamp rule; some sites may hang for clients' >&2
fi

# ipsec (pluto)
echo 'starting pluto ...'
mkdir -p /run/pluto
ipsec initnss > /dev/null 2>&1 || true
# pluto daemonizes itself; --stderrlog keeps its output in `docker logs`.
ipsec pluto --config /etc/ipsec.conf --stderrlog

# Wait for the pluto control socket, then load the connections
# (auto=add conns are loaded by addconn, not by pluto itself).
declare -i i=0
while [[ ! -S /run/pluto/pluto.ctl && $i -lt 30 ]]; do
    sleep 0.5
    i+=1
done
[[ -S /run/pluto/pluto.ctl ]] || { echo 'pluto failed to start' >&2; exit 1; }
ipsec addconn --config /etc/ipsec.conf --autoall

echo 'verifying ipsec ...'
# awk consumes the whole stream — head would close the pipe early and make
# whack flood the log with EPIPE errors.
ipsec status | awk 'NR <= 20' || :

# xl2tpd in the foreground keeps the container alive
echo 'starting xl2tpd ...'
mkdir -p /var/run/xl2tpd
exec /usr/sbin/xl2tpd -D -c /etc/xl2tpd/xl2tpd.conf
