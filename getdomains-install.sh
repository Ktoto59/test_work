#!/bin/sh
# OpenWrt 25.12.1+
# WireGuard + russia_inside + forced DNS hijack + DoH upstream
# Uses apk (not opkg)

set -e

WG_IF="wg0"
ROUTE_TABLE_NAME="vpn"
ROUTE_TABLE_ID="99"

IPSET_NAME="vpn_domains"
MARK_HEX="0x1"

LAN_ZONE="lan"
WG_ZONE="vpn"

DOH_SECTION="cloudflare"
DOH_LISTEN_ADDR="127.0.0.1"
DOH_LISTEN_PORT="5053"
DOH_BOOTSTRAP_DNS="1.1.1.1,1.0.0.1"
DOH_RESOLVER_URL="https://cloudflare-dns.com/dns-query"

# Источник russia_inside.
# Если у тебя есть точный URL из старого скрипта — подставь его сюда.
# Этот URL рабочий как типичный antifilter domains list, но если нужен ИМЕННО твой старый источник — лучше заменить.
DOMAINS_URL="https://antifilter.download/list/domains.lst"

DOMAINS_RAW="/tmp/${IPSET_NAME}_raw.lst"
DOMAINS_CLEAN="/tmp/${IPSET_NAME}_clean.lst"
UPDATE_SCRIPT="/usr/local/bin/wg-russia-inside-update.sh"

# ---------------- helpers ----------------

log() {
    echo "[*] $*"
}

warn() {
    echo "[!] $*" >&2
}

die() {
    echo "[x] $*" >&2
    exit 1
}

pkg_installed() {
    apk info -e "$1" >/dev/null 2>&1
}

pkg_install() {
    PKG="$1"
    if pkg_installed "$PKG"; then
        log "Package already installed: $PKG"
    else
        log "Installing package: $PKG"
        apk update
        apk add "$PKG"
    fi
}

ensure_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

uci_delete_sections_by_type_and_match() {
    # $1=config $2=type $3=grep_pattern
    CFG="$1"
    TYPE="$2"
    PATTERN="$3"

    uci show "$CFG" 2>/dev/null | grep "=$TYPE" | cut -d= -f1 | while read -r SEC; do
        if uci show "$SEC" 2>/dev/null | grep -q "$PATTERN"; then
            uci delete "$SEC"
        fi
    done
}

ensure_rt_table() {
    if ! grep -qE "^[[:space:]]*${ROUTE_TABLE_ID}[[:space:]]+${ROUTE_TABLE_NAME}\$" /etc/iproute2/rt_tables 2>/dev/null; then
        log "Adding routing table ${ROUTE_TABLE_ID} ${ROUTE_TABLE_NAME}"
        echo "${ROUTE_TABLE_ID} ${ROUTE_TABLE_NAME}" >> /etc/iproute2/rt_tables
    else
        log "Routing table already exists: ${ROUTE_TABLE_NAME}"
    fi
}

# ---------------- wireguard ----------------

ensure_wg_config() {
    if uci -q get network."$WG_IF" >/dev/null 2>&1; then
        log "WireGuard interface ${WG_IF} already exists"
        return 0
    fi

    log "WireGuard interface ${WG_IF} not found. Enter config."

    printf "Enter private key: "
    read -r WG_PRIVATE_KEY

    printf "Enter WG internal IP CIDR (example 10.66.66.2/24): "
    read -r WG_IP

    printf "Enter peer public key: "
    read -r WG_PUBLIC_KEY

    printf "Enter peer endpoint host: "
    read -r WG_ENDPOINT_HOST

    printf "Enter peer endpoint port: "
    read -r WG_ENDPOINT_PORT

    uci set network."$WG_IF"='interface'
    uci set network."$WG_IF".proto='wireguard'
    uci set network."$WG_IF".private_key="$WG_PRIVATE_KEY"
    uci -q delete network."$WG_IF".addresses
    uci add_list network."$WG_IF".addresses="$WG_IP"

    uci add network wireguard_"$WG_IF" >/dev/null
    uci set network.@wireguard_"$WG_IF"[-1].description='wg-peer'
    uci set network.@wireguard_"$WG_IF"[-1].public_key="$WG_PUBLIC_KEY"
    uci set network.@wireguard_"$WG_IF"[-1].route_allowed_ips='0'
    uci add_list network.@wireguard_"$WG_IF"[-1].allowed_ips='0.0.0.0/0'
    uci add_list network.@wireguard_"$WG_IF"[-1].allowed_ips='::/0'
    uci set network.@wireguard_"$WG_IF"[-1].endpoint_host="$WG_ENDPOINT_HOST"
    uci set network.@wireguard_"$WG_IF"[-1].endpoint_port="$WG_ENDPOINT_PORT"
    uci set network.@wireguard_"$WG_IF"[-1].persistent_keepalive='25'

    uci commit network
    /etc/init.d/network restart
}

ensure_wg_zone() {
    if ! uci show firewall 2>/dev/null | grep -q "name='${WG_ZONE}'"; then
        log "Creating firewall zone: ${WG_ZONE}"

        uci add firewall zone >/dev/null
        uci set firewall.@zone[-1].name="${WG_ZONE}"
        uci add_list firewall.@zone[-1].network="${WG_IF}"
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'

        uci add firewall forwarding >/dev/null
        uci set firewall.@forwarding[-1].src="${LAN_ZONE}"
        uci set firewall.@forwarding[-1].dest="${WG_ZONE}"

        uci commit firewall
        /etc/init.d/firewall restart
    else
        log "Firewall zone ${WG_ZONE} already exists"
    fi
}

# ---------------- firewall ipset / dns tagging ----------------

ensure_firewall_ipset() {
    uci_delete_sections_by_type_and_match firewall ipset "name='${IPSET_NAME}'"

    log "Creating firewall ipset section: ${IPSET_NAME}"
    uci add firewall ipset >/dev/null
    uci set firewall.@ipset[-1].name="${IPSET_NAME}"
    uci set firewall.@ipset[-1].family='ipv4'
    uci set firewall.@ipset[-1].match='dst_net'
    uci commit firewall
}

apply_domains_to_dnsmasq_ipset() {
    uci_delete_sections_by_type_and_match dhcp ipset "name='${IPSET_NAME}'"

    log "Creating dnsmasq ipset domain section: ${IPSET_NAME}"
    uci add dhcp ipset >/dev/null
    uci set dhcp.@ipset[-1].name="${IPSET_NAME}"

    while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        uci add_list dhcp.@ipset[-1].domain="$domain"
    done < "$DOMAINS_CLEAN"

    uci commit dhcp
}

# ---------------- dns / doh ----------------

ensure_https_dns_proxy() {
    log "Configuring https-dns-proxy"

    # Удаляем старые секции с тем же именем
    uci -q delete https-dns-proxy.config || true
    uci -q delete https-dns-proxy."$DOH_SECTION" || true

    uci set https-dns-proxy.config='main'
    uci set https-dns-proxy.config.update_dnsmasq_config='-1'
    uci set https-dns-proxy.config.force_dns='0'

    uci set https-dns-proxy."$DOH_SECTION"='https-dns-proxy'
    uci set https-dns-proxy."$DOH_SECTION".bootstrap_dns="$DOH_BOOTSTRAP_DNS"
    uci set https-dns-proxy."$DOH_SECTION".resolver_url="$DOH_RESOLVER_URL"
    uci set https-dns-proxy."$DOH_SECTION".listen_addr="$DOH_LISTEN_ADDR"
    uci set https-dns-proxy."$DOH_SECTION".listen_port="$DOH_LISTEN_PORT"
    uci set https-dns-proxy."$DOH_SECTION".user='nobody'
    uci set https-dns-proxy."$DOH_SECTION".group='nogroup'

    uci commit https-dns-proxy

    /etc/init.d/https-dns-proxy enable || true
    /etc/init.d/https-dns-proxy restart
}

ensure_dnsmasq_upstream_doh() {
    log "Configuring dnsmasq -> local DoH proxy only"

    uci -q set dhcp.@dnsmasq[0].noresolv='1'
    uci -q delete dhcp.@dnsmasq[0].server || true
    uci add_list dhcp.@dnsmasq[0].server="${DOH_LISTEN_ADDR}#${DOH_LISTEN_PORT}"

    uci -q set dhcp.@dnsmasq[0].domainneeded='1'
    uci -q set dhcp.@dnsmasq[0].boguspriv='1'
    uci -q set dhcp.@dnsmasq[0].localservice='1'

    uci commit dhcp
}

ensure_dns_hijack() {
    uci_delete_sections_by_type_and_match firewall redirect "name='Force-DNS-UDP'"
    uci_delete_sections_by_type_and_match firewall redirect "name='Force-DNS-TCP'"

    log "Adding DNS hijack rules (LAN -> router:53)"

    # UDP 53
    uci add firewall redirect >/dev/null
    uci set firewall.@redirect[-1].name='Force-DNS-UDP'
    uci set firewall.@redirect[-1].src="${LAN_ZONE}"
    uci set firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_port='53'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].family='ipv4'

    # TCP 53
    uci add firewall redirect >/dev/null
    uci set firewall.@redirect[-1].name='Force-DNS-TCP'
    uci set firewall.@redirect[-1].src="${LAN_ZONE}"
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_port='53'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].family='ipv4'

    uci commit firewall
}

# ---------------- mark / routing ----------------

ensure_mark_rule() {
    uci_delete_sections_by_type_and_match firewall rule "name='Mark-VPN-Domains'"

    log "Adding mark rule for ipset ${IPSET_NAME}"

    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='Mark-VPN-Domains'
    uci set firewall.@rule[-1].src="${LAN_ZONE}"
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].family='ipv4'
    uci set firewall.@rule[-1].ipset="${IPSET_NAME} dest"
    uci set firewall.@rule[-1].target='MARK'
    uci set firewall.@rule[-1].set_mark="${MARK_HEX}"

    uci commit firewall
}

ensure_policy_routing() {
    log "Configuring policy routing"

    if ! ip link show "$WG_IF" >/dev/null 2>&1; then
        warn "WireGuard interface ${WG_IF} is not up, restarting network"
        /etc/init.d/network restart
        sleep 3
    fi

    # Удалим возможные старые дубли для этого fwmark/table
    while ip rule show | grep -q "fwmark ${MARK_HEX#0x}.*lookup ${ROUTE_TABLE_NAME}"; do
        RULE_PRIO="$(ip rule show | awk "/fwmark ${MARK_HEX#0x}.*lookup ${ROUTE_TABLE_NAME}/ {gsub(/:/, \"\", \$1); print \$1; exit}")"
        [ -n "$RULE_PRIO" ] || break
        ip rule del priority "$RULE_PRIO" || break
    done

    ip rule add fwmark "$MARK_HEX" table "$ROUTE_TABLE_NAME" priority 10000
    ip route replace default dev "$WG_IF" table "$ROUTE_TABLE_NAME"
}

# ---------------- domains ----------------

download_domains() {
    log "Downloading domain list: ${DOMAINS_URL}"

    rm -f "$DOMAINS_RAW" "$DOMAINS_CLEAN"
    mkdir -p /tmp

    curl -fsSL "$DOMAINS_URL" -o "$DOMAINS_RAW"

    [ -s "$DOMAINS_RAW" ] || die "Downloaded list is empty"

    sed 's/\r$//' "$DOMAINS_RAW" \
        | sed 's/^[.]//' \
        | sed '/^[[:space:]]*#/d' \
        | sed '/^[[:space:]]*$/d' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[[:space:]]//g' \
        | grep -E '^[a-z0-9._-]+\.[a-z0-9._-]+$' \
        | sort -u > "$DOMAINS_CLEAN"

    [ -s "$DOMAINS_CLEAN" ] || die "Cleaned domain list is empty"

    log "Prepared domains: $(wc -l < "$DOMAINS_CLEAN")"
}

# ---------------- services ----------------

restart_services() {
    log "Restarting services"
    /etc/init.d/https-dns-proxy restart
    /etc/init.d/dnsmasq enable || true
    /etc/init.d/dnsmasq restart
    /etc/init.d/firewall enable || true
    /etc/init.d/firewall restart
}

verify_doh_listener() {
    log "Verifying DoH local listener"

    sleep 2

    if ss -lntup 2>/dev/null | grep -q ":${DOH_LISTEN_PORT} "; then
        log "DoH listener is up on ${DOH_LISTEN_ADDR}:${DOH_LISTEN_PORT}"
    else
        warn "DoH listener not detected on ${DOH_LISTEN_ADDR}:${DOH_LISTEN_PORT}"
        warn "Check: logread | grep https-dns-proxy"
    fi
}

# ---------------- updater script ----------------

install_update_script() {
    log "Installing updater script: ${UPDATE_SCRIPT}"

    cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/sh
set -e

IPSET_NAME="vpn_domains"
DOMAINS_URL="https://antifilter.download/list/domains.lst"
DOMAINS_RAW="/tmp/${IPSET_NAME}_raw.lst"
DOMAINS_CLEAN="/tmp/${IPSET_NAME}_clean.lst"

log() {
    echo "[update] $*"
}

uci_delete_sections_by_type_and_match() {
    CFG="$1"
    TYPE="$2"
    PATTERN="$3"

    uci show "$CFG" 2>/dev/null | grep "=$TYPE" | cut -d= -f1 | while read -r SEC; do
        if uci show "$SEC" 2>/dev/null | grep -q "$PATTERN"; then
            uci delete "$SEC"
        fi
    done
}

log "Downloading updated domains"
rm -f "$DOMAINS_RAW" "$DOMAINS_CLEAN"

curl -fsSL "$DOMAINS_URL" -o "$DOMAINS_RAW"

[ -s "$DOMAINS_RAW" ] || {
    log "Downloaded list is empty"
    exit 1
}

sed 's/\r$//' "$DOMAINS_RAW" \
    | sed 's/^[.]//' \
    | sed '/^[[:space:]]*#/d' \
    | sed '/^[[:space:]]*$/d' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[[:space:]]//g' \
    | grep -E '^[a-z0-9._-]+\.[a-z0-9._-]+$' \
    | sort -u > "$DOMAINS_CLEAN"

[ -s "$DOMAINS_CLEAN" ] || {
    log "Cleaned list is empty"
    exit 1
}

uci_delete_sections_by_type_and_match dhcp ipset "name='${IPSET_NAME}'"

uci add dhcp ipset >/dev/null
uci set dhcp.@ipset[-1].name="${IPSET_NAME}"

while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    uci add_list dhcp.@ipset[-1].domain="$domain"
done < "$DOMAINS_CLEAN"

uci commit dhcp
/etc/init.d/dnsmasq restart

log "Updated domains: $(wc -l < "$DOMAINS_CLEAN")"
EOF

    chmod +x "$UPDATE_SCRIPT"
}

install_cron_job() {
    log "Installing daily cron update"

    CRON_LINE="0 5 * * * ${UPDATE_SCRIPT} >/tmp/wg-russia-inside-update.log 2>&1"

    CRON_TMP="/tmp/root.cron.$$"
    crontab -l 2>/dev/null | grep -vF "$UPDATE_SCRIPT" > "$CRON_TMP" || true
    echo "$CRON_LINE" >> "$CRON_TMP"
    crontab "$CRON_TMP"
    rm -f "$CRON_TMP"

    /etc/init.d/cron enable || true
    /etc/init.d/cron restart
}

# ---------------- main ----------------

main() {
    ensure_cmd apk
    ensure_cmd uci
    ensure_cmd curl
    ensure_cmd ip
    ensure_cmd ss

    log "Ensuring required packages (apk)"
    pkg_install dnsmasq-full
    pkg_install curl
    pkg_install ca-bundle
    pkg_install wireguard-tools
    pkg_install kmod-wireguard
    pkg_install https-dns-proxy

    ensure_rt_table
    ensure_wg_config
    ensure_wg_zone

    ensure_firewall_ipset
    ensure_https_dns_proxy
    ensure_dnsmasq_upstream_doh
    ensure_dns_hijack

    download_domains
    apply_domains_to_dnsmasq_ipset

    ensure_mark_rule
    restart_services
    verify_doh_listener
    ensure_policy_routing

    install_update_script
    install_cron_job

    echo
    echo "========================================"
    echo "Setup complete"
    echo "========================================"
    echo "WG interface:           ${WG_IF}"
    echo "Routing table:          ${ROUTE_TABLE_NAME} (${ROUTE_TABLE_ID})"
    echo "Mark:                   ${MARK_HEX}"
    echo "IPSET:                  ${IPSET_NAME}"
    echo "DoH local listener:     ${DOH_LISTEN_ADDR}:${DOH_LISTEN_PORT}"
    echo "DNS hijack:             LAN ${LAN_ZONE} TCP/UDP 53 -> router:53"
    echo "Domains source:         ${DOMAINS_URL}"
    echo "Updater script:         ${UPDATE_SCRIPT}"
    echo
    echo "Checks:"
    echo "  logread | grep https-dns-proxy"
    echo "  ss -lntup | grep :${DOH_LISTEN_PORT}"
    echo "  ip rule show"
    echo "  ip route show table ${ROUTE_TABLE_NAME}"
    echo "  nft list ruleset | grep -i 53"
    echo "========================================"
    echo
}

main "$@"
