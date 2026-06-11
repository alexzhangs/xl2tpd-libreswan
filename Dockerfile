# Description:
#   This Dockerfile builds an L2TP/IPsec (PSK) VPN server image: libreswan
#   (IKEv1 PSK) + xl2tpd + pppd. It supersedes the host installer
#   https://github.com/alexzhangs/aws-ec2-xl2tpd (Amazon Linux 2 reaches end
#   of support on 2026-06-30; its EPEL openswan/xl2tpd packages have no
#   AL2023 equivalent), the same way shadowsocks-libev-v2ray superseded
#   aws-ec2-shadowsocks-libev.
#
#   The container is self-contained: it renders all configs from environment
#   variables at startup and manages its own NAT rule. No IMDS or
#   cloud-specific dependency.
#
# Expose (documentation only — run with --network=host, see below):
#   - 500/udp:  IKE
#   - 4500/udp: IPsec NAT-Traversal
#   - 1701/udp: L2TP (only reachable through the IPsec tunnel)
#
# Build:
#   docker build -t alexzhangs/xl2tpd-libreswan .
#   docker build --platform linux/amd64 -t alexzhangs/xl2tpd-libreswan .
#
# Run:
#
#   IPSEC_PSK=your_psk L2TP_USERNAME=your_user L2TP_PASSWORD=your_password
#
#   docker run -d --name l2tpd --restart=always \
#     --privileged --network=host \
#     -v /lib/modules:/lib/modules:ro \
#     -e IPSEC_PSK="$IPSEC_PSK" \
#     -e L2TP_USERNAME="$L2TP_USERNAME" \
#     -e L2TP_PASSWORD="$L2TP_PASSWORD" \
#     alexzhangs/xl2tpd-libreswan
#
#   Why --privileged + --network=host + /lib/modules:
#     - pppd needs /dev/ppp (the entrypoint modprobes ppp_generic and mknods
#       the device — both need privileged and the host's kernel modules).
#     - IKE/NAT-T must terminate on the host's UDP 500/4500, and the
#       MASQUERADE rule for the client pool must live in the host netns.
#     - net.ipv4.ip_forward & co. are written by the entrypoint (host netns).
#
#   Manage additional L2TP users at runtime (bundled chap-manager):
#     docker exec l2tpd chap-manager.sh -a add -u user2 -p pass2
#     docker exec l2tpd chap-manager.sh -a delete -u user2
#   Persist users across container re-creation with:
#     -v l2tp-ppp:/etc/ppp
#
# For more information, please refer to the project repository:
#   https://github.com/alexzhangs/xl2tpd-libreswan
#

# To enable proxy at build time, use:
# docker build --build-arg https_proxy=http://host.docker.internal:$PROXY_HTTP_PORT_ON_HOST ...
ARG http_proxy https_proxy all_proxy

# Pinned by digest for reproducible builds (debian:bookworm-slim as of 2026-06-11).
# Bump deliberately (e.g. via Dependabot/Renovate Docker digest updates).
# bookworm ships libreswan 4.x + xl2tpd in main — no third-party repo needed.
FROM debian@sha256:66117fe525ba266a4d9de1dc238fa9b9d2fe78ff9d0836b8348d133e836f39b5

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        # IKEv1/IPsec daemon (pluto)
        libreswan \
        # L2TP daemon + PPP
        xl2tpd ppp \
        # NAT rule for the client pool; default-route interface detection
        iptables iproute2 \
        # sysctl at startup
        procps \
        # modprobe ppp_generic from the host's /lib/modules
        kmod \
        # used to fetch the pinned chap-manager release below
        ca-certificates git && \
    rm -rf /var/lib/apt/lists/*

# Install chap-manager (manage /etc/ppp/chap-secrets entries), pinned to a
# commit instead of the default-branch HEAD.
RUN git clone https://github.com/alexzhangs/chap-manager.git /tmp/chap-manager && \
    git -C /tmp/chap-manager checkout bd0469fe0a8709148859340ec58724145ff65cbd && \
    install -m 755 /tmp/chap-manager/chap-manager.sh /usr/local/bin/chap-manager.sh && \
    rm -rf /tmp/chap-manager

# Set work directory
WORKDIR /xl2tpd-libreswan

# Copy the config templates and the entrypoint
COPY conf ./conf
COPY docker-entrypoint.sh .

RUN chmod +x docker-entrypoint.sh

EXPOSE 500/udp 4500/udp 1701/udp

ENTRYPOINT ["/xl2tpd-libreswan/docker-entrypoint.sh"]
