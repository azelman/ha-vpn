#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
set -Eeuo pipefail

readonly CONNECTION="ha-ikev2"
readonly RUNTIME_DIR="/run/ha-ikev2"
readonly P12_ERROR_LOG="${RUNTIME_DIR}/p12-openssl-errors.log"
DAEMON_PID=""

fail() {
    bashio::log.fatal "$1"
    exit 1
}

get_optional() {
    local key="$1"
    if bashio::config.has_value "${key}"; then
        bashio::config "${key}"
    else
        printf ''
    fi
}

reject_control_characters() {
    local label="$1"
    local value="$2"
    [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || \
        fail "${label} must not contain line breaks"
}

validate_relative_file() {
    local label="$1"
    local value="$2"
    [[ -n "${value}" ]] || fail "${label} is required"
    [[ "${value}" == "$(basename -- "${value}")" && "${value}" != "." && "${value}" != ".." ]] || \
        fail "${label} must be a file name in the app configuration directory, not a path"
    [[ -f "/config/${value}" ]] || fail "${label} '/config/${value}' does not exist"
}

escape_secret() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "${value}"
}

normalize_ipv4_subnets() {
    local input="$1"
    local subnet="" address="" prefix="" octet="" normalized=""
    local -a subnets octets
    IFS=',' read -ra subnets <<< "${input}"
    ((${#subnets[@]} > 0)) || fail "remote_subnets must not be empty"

    for subnet in "${subnets[@]}"; do
        subnet="${subnet//[[:space:]]/}"
        [[ "${subnet}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || \
            fail "Invalid IPv4 CIDR in remote_subnets: ${subnet}"
        address="${subnet%/*}"
        prefix="${subnet#*/}"
        IFS='.' read -ra octets <<< "${address}"
        for octet in "${octets[@]}"; do
            ((10#${octet} <= 255)) || fail "Invalid IPv4 address in remote_subnets: ${address}"
        done
        [[ -z "${normalized}" ]] || normalized+=","
        normalized+="${address}/${prefix}"
    done
    printf '%s' "${normalized}"
}

cleanup() {
    trap - EXIT INT TERM
    bashio::log.info "Disconnecting IKEv2 VPN..."
    ipsec down "${CONNECTION}" >/dev/null 2>&1 || true
    ipsec stop >/dev/null 2>&1 || true
    if [[ -n "${DAEMON_PID}" ]]; then
        wait "${DAEMON_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

SERVER="$(bashio::config server)"
SERVER_ID="$(bashio::config server_id)"
AUTHENTICATION="$(bashio::config authentication)"
CLIENT_ID="$(get_optional client_id)"
P12_FILE="$(get_optional p12_file)"
P12_PASSWORD="$(get_optional p12_password)"
USERNAME="$(get_optional username)"
PASSWORD="$(get_optional password)"
PRE_SHARED_KEY="$(get_optional pre_shared_key)"
SERVER_CA_FILE="$(get_optional server_ca_file)"
REMOTE_SUBNETS="$(bashio::config remote_subnets)"
IKE_PROPOSALS="$(get_optional ike_proposals)"
ESP_PROPOSALS="$(get_optional esp_proposals)"
FORCE_ENCAP="$(bashio::config force_udp_encapsulation)"
RECONNECT_INTERVAL="$(bashio::config reconnect_interval)"
LOG_LEVEL="$(bashio::config log_level)"

for pair in \
    "server ID:${SERVER_ID}" \
    "client ID:${CLIENT_ID}" \
    "username:${USERNAME}" \
    "remote subnets:${REMOTE_SUBNETS}" \
    "IKE proposals:${IKE_PROPOSALS}" \
    "ESP proposals:${ESP_PROPOSALS}"; do
    reject_control_characters "${pair%%:*}" "${pair#*:}"
done
reject_control_characters "PKCS#12 password" "${P12_PASSWORD}"
reject_control_characters "EAP password" "${PASSWORD}"
reject_control_characters "pre-shared key" "${PRE_SHARED_KEY}"

[[ "${SERVER_ID}" != *"#"* ]] || fail "server_id must not contain '#'"
[[ "${CLIENT_ID}" != *"#"* ]] || fail "client_id must not contain '#'"
[[ "${USERNAME}" != *"#"* ]] || fail "username must not contain '#'"
REMOTE_SUBNETS="$(normalize_ipv4_subnets "${REMOTE_SUBNETS}")"
[[ "${IKE_PROPOSALS}" =~ ^[A-Za-z0-9_,+!-]*$ ]] || fail "ike_proposals contains invalid characters"
[[ "${ESP_PROPOSALS}" =~ ^[A-Za-z0-9_,+!-]*$ ]] || fail "esp_proposals contains invalid characters"

mkdir -p "${RUNTIME_DIR}"
chmod 0700 "${RUNTIME_DIR}"
rm -f /etc/ipsec.d/cacerts/ha-* /etc/ipsec.d/certs/ha-* /etc/ipsec.d/private/ha-*
: > /etc/ipsec.secrets
chmod 0600 /etc/ipsec.secrets

case "${LOG_LEVEL}" in
    error) CHARON_DEBUG=0 ;;
    warning) CHARON_DEBUG=1 ;;
    info) CHARON_DEBUG=2 ;;
    debug) CHARON_DEBUG=4 ;;
    *) fail "Unsupported log level: ${LOG_LEVEL}" ;;
esac

AUTH_CONFIG=""
case "${AUTHENTICATION}" in
    certificate)
        validate_relative_file "p12_file" "${P12_FILE}"
        [[ -n "${CLIENT_ID}" ]] || fail "client_id is required for certificate authentication"
        printf '%s' "${P12_PASSWORD}" > "${RUNTIME_DIR}/p12-password"
        chmod 0600 "${RUNTIME_DIR}/p12-password"
        bashio::log.info "Reading PKCS#12 bundle /config/${P12_FILE} ($(stat -c '%s bytes' "/config/${P12_FILE}" 2>/dev/null || printf 'size unavailable'))"
        bashio::log.info "PKCS#12 decoder: $(openssl version 2>/dev/null || printf 'OpenSSL version unavailable')"
        : > "${P12_ERROR_LOG}"
        chmod 0600 "${P12_ERROR_LOG}"

        extract_p12() {
            local legacy_flag="${1:-}"
            local -a legacy_args=()
            [[ -z "${legacy_flag}" ]] || legacy_args+=("${legacy_flag}")
            openssl pkcs12 "${legacy_args[@]}" -in "/config/${P12_FILE}" \
                -passin "file:${RUNTIME_DIR}/p12-password" -cacerts -nokeys \
                -out /etc/ipsec.d/cacerts/ha-ca.pem 2>>"${P12_ERROR_LOG}" \
            && openssl pkcs12 "${legacy_args[@]}" -in "/config/${P12_FILE}" \
                -passin "file:${RUNTIME_DIR}/p12-password" -clcerts -nokeys \
                -out /etc/ipsec.d/certs/ha-client.pem 2>>"${P12_ERROR_LOG}" \
            && openssl pkcs12 "${legacy_args[@]}" -in "/config/${P12_FILE}" \
                -passin "file:${RUNTIME_DIR}/p12-password" -nocerts -nodes \
                -out /etc/ipsec.d/private/ha-client.key 2>>"${P12_ERROR_LOG}"
        }

        if ! extract_p12; then
            bashio::log.warning "Normal PKCS#12 decoding failed; retrying with OpenSSL legacy providers"
            if ! extract_p12 "-legacy"; then
                bashio::log.error "PKCS#12 decoding failed in normal and legacy modes"
                if [[ -s "${P12_ERROR_LOG}" ]]; then
                    bashio::log.error "OpenSSL diagnostics: $(tr '\n' ' ' < "${P12_ERROR_LOG}" | sed -E 's/[[:space:]]+/ /g' | cut -c1-1000)"
                else
                    bashio::log.error "OpenSSL returned no diagnostic output"
                fi
                fail "Unable to decode /config/${P12_FILE}; check the file and p12_password"
            fi
        fi
        openssl x509 -in /etc/ipsec.d/certs/ha-client.pem -noout >/dev/null 2>&1 || \
            fail "The PKCS#12 bundle does not contain a readable client certificate"
        openssl x509 -in /etc/ipsec.d/cacerts/ha-ca.pem -noout >/dev/null 2>&1 || \
            fail "The PKCS#12 bundle does not contain a readable CA certificate"
        openssl pkey -in /etc/ipsec.d/private/ha-client.key -noout >/dev/null 2>&1 || \
            fail "The PKCS#12 bundle does not contain a readable private key"
        chmod 0600 /etc/ipsec.d/cacerts/ha-ca.pem \
            /etc/ipsec.d/certs/ha-client.pem /etc/ipsec.d/private/ha-client.key
        printf ': RSA ha-client.key\n' > /etc/ipsec.secrets
        AUTH_CONFIG="  leftauth=pubkey
  leftid=${CLIENT_ID}
  leftcert=ha-client.pem
  leftsendcert=always
  rightauth=pubkey"
        ;;
    eap-mschapv2)
        [[ -n "${USERNAME}" ]] || fail "username is required for EAP-MSCHAPv2 authentication"
        [[ -n "${PASSWORD}" ]] || fail "password is required for EAP-MSCHAPv2 authentication"
        validate_relative_file "server_ca_file" "${SERVER_CA_FILE}"
        if ! openssl x509 -in "/config/${SERVER_CA_FILE}" -out /etc/ipsec.d/cacerts/ha-server-ca.pem 2>/dev/null; then
            openssl x509 -inform DER -in "/config/${SERVER_CA_FILE}" \
                -out /etc/ipsec.d/cacerts/ha-server-ca.pem 2>/dev/null || \
                fail "server_ca_file is not a valid PEM or DER X.509 certificate"
        fi
        chmod 0600 /etc/ipsec.d/cacerts/ha-server-ca.pem
        printf '"%s" : EAP "%s"\n' "$(escape_secret "${USERNAME}")" "$(escape_secret "${PASSWORD}")" > /etc/ipsec.secrets
        AUTH_CONFIG="  leftauth=eap-mschapv2
  leftid=${USERNAME}
  eap_identity=${USERNAME}
  rightauth=pubkey"
        ;;
    psk)
        [[ -n "${PRE_SHARED_KEY}" ]] || fail "pre_shared_key is required for PSK authentication"
        [[ -n "${CLIENT_ID}" ]] || CLIENT_ID="%any"
        printf ': PSK "%s"\n' "$(escape_secret "${PRE_SHARED_KEY}")" > /etc/ipsec.secrets
        AUTH_CONFIG="  leftauth=psk
  leftid=${CLIENT_ID}
  rightauth=psk"
        ;;
    *) fail "Unsupported authentication mode: ${AUTHENTICATION}" ;;
esac
chmod 0600 /etc/ipsec.secrets

EXTRA_CONFIG=""
[[ -z "${IKE_PROPOSALS}" ]] || EXTRA_CONFIG+=$'\n'"  ike=${IKE_PROPOSALS}"
[[ -z "${ESP_PROPOSALS}" ]] || EXTRA_CONFIG+=$'\n'"  esp=${ESP_PROPOSALS}"
[[ "${FORCE_ENCAP}" != "true" ]] || EXTRA_CONFIG+=$'\n'"  forceencaps=yes"

cat > /etc/ipsec.conf <<EOF
config setup
  uniqueids=no
  charondebug="ike ${CHARON_DEBUG}, cfg ${CHARON_DEBUG}, knl ${CHARON_DEBUG}, net ${CHARON_DEBUG}"

conn ${CONNECTION}
  keyexchange=ikev2
  type=tunnel
  auto=add
  left=%defaultroute
  leftsourceip=%config4
${AUTH_CONFIG}
  right=${SERVER}
  rightid=${SERVER_ID}
  rightsubnet=${REMOTE_SUBNETS}
  fragmentation=yes
  mobike=no
  reauth=no
  keyingtries=1
  dpdaction=restart
  dpddelay=30s
  closeaction=restart${EXTRA_CONFIG}
EOF
chmod 0600 /etc/ipsec.conf

bashio::log.info "Starting strongSwan IKEv2 client for ${SERVER}"
bashio::log.info "Authentication: ${AUTHENTICATION}; remote networks: ${REMOTE_SUBNETS}"
ipsec start --nofork &
DAEMON_PID=$!

for _ in $(seq 1 30); do
    kill -0 "${DAEMON_PID}" 2>/dev/null || fail "strongSwan exited during startup"
    if ipsec status >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
ipsec status >/dev/null 2>&1 || fail "strongSwan control socket did not become ready"

if ipsec up "${CONNECTION}"; then
    bashio::log.info "IKEv2 VPN connected"
else
    bashio::log.warning "Initial connection failed; the app will keep retrying"
fi

is_tunnel_up() {
    local status
    status="$(ipsec status "${CONNECTION}" 2>/dev/null || true)"
    [[ "${status}" == *"INSTALLED"* ]]
}

while kill -0 "${DAEMON_PID}" 2>/dev/null; do
    sleep "${RECONNECT_INTERVAL}" &
    wait $! || true
    if ! is_tunnel_up; then
        bashio::log.warning "IKEv2 tunnel is down; reconnecting..."
        ipsec down "${CONNECTION}" >/dev/null 2>&1 || true
        ipsec up "${CONNECTION}" || true
    fi
done

wait "${DAEMON_PID}"
