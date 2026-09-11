FROM ghcr.io/home-assistant/base:3.22

ARG BUILD_ARCH
ARG BUILD_VERSION
LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}" \
    org.opencontainers.image.title="Home Assistant IKEv2 VPN Client" \
    org.opencontainers.image.description="strongSwan IKEv2 client for Home Assistant" \
    org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache \
        iproute2 \
        openssl \
        strongswan \
    && mkdir -p /etc/ipsec.d/cacerts /etc/ipsec.d/certs /etc/ipsec.d/private

COPY run.sh /run.sh
RUN chmod 0755 /run.sh

CMD [ "/run.sh" ]
