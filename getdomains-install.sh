#!/bin/sh
# OpenWrt 25.x / 24.x
# WireGuard + russia_inside domain routing + forced DNS hijack + DoH upstream
#
# What it does:
# 1) Forces all LAN clients' DNS (TCP/UDP 53) to the router
# 2) Runs dnsmasq as local DNS on 53
# 3) Sends dnsmasq upstream DNS to local DoH proxy on 127.0.0.1:5053
# 4) Downloads russia_inside domain list
# 5) Adds domains to dnsmasq ipset/nftset tagging
# 6) Marks packets to those resolved IPs and routes them via WireGuard
#
# IMPORTANT:
# - Requires firewall4/nftables-compatible OpenWrt (modern OpenWrt)
# - Uses ipset UCI sections because dnsmasq/firewall UCI on OpenWrt handles translation
# - If your build has dnsmasq-full already, good. If not, it installs it.
#
# Author: v3 for user case "provider hijacks port 53"

set -e

WG_IF="wg0"
ROUTE_TABLE_NAME="vpn"
ROUTE_TABLE_ID="99"

IPSET_NAME="vpn_domains"

# Source list for russia_inside (Antifilter)
# If this URL dies, replace it with your known-good source.
DOMAINS_URL="https://antifilter.download/list/domains.lst"

DOMAINS_RAW="/tmp/${IPSET_NAME}_raw.lst"
DOMAINS_CLEAN="/tmp/${IPSET_NAME}_clean.lst"

DOH_SECTION="cloudflare"
DOH_LISTEN_ADDR="127.0.0.1"
DOH_LISTEN_PORT="5053"

# Cloudflare DoH by default (change if needed)
DOH_BOOTSTRAP_DNS="1.1.1.1,1.0.0.1"
DOH_RESOLVER_URL="https://cloudflare-dns.com/dns-query"

LAN_IF="br-lan"
MARK_HEX="0x1"

# ---------- helpers ----------

log() {
    echo "[*] $*"
}

warn() {
    echo "[!] $*" >&2
}

have_pkg() {
    opkg list-installed | grep -q "^$1 "
}

ensure_pkg() {
    if ! have_pkg "$1"; then
        log "Installing package: $1"
        opkg update
        opkg install "$1"
    else
        log "Package already installed: $1"
    fi
}

uci_commit_if_changed() {
    uci commit "$1"
}

delete_all_matching_uci_sections() {
    # $1=config name, $2=section type, $3=grep pattern
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
        log "Routing table exists: ${ROUTE_TABLE_NAME}"
    fi
}

ensure_wg_config() {
    if uci -q get network."$WG_IF" >/dev/null 2>&1; then
        log "WireGuard interface ${WG_IF} already exists in UCI"
        return 0
    fi

    log "WireGuard interface ${WG_IF} not found. Enter config now."

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

ensure_wg_firewall_zone() {
    if ! uci show firewall 2>/dev/null | grep -q "name='vpn'"; then
        log "Creating firewall zone: vpn"

        uci add firewall zone >/dev/null
        uci set firewall.@zone[-1].name='vpn'
        uci add_list firewall.@zone[-1].network="$WG_IF"
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'

        # lan -> vpn forward
        uci add firewall forwarding >/dev/null
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='vpn'

        uci commit firewall
        /etc/init.d/firewall restart
    else
        log "Firewall zone vpn already exists"
    fi
}

ensure_ipset_section() {
    # Clean old duplicates
    delete_all_matching_uci_sections firewall ipset "name='${IPSET_NAME}'"

    log "Creating firewall ipset section: ${IPSET_NAME}"
    uci add firewall ipset >/dev/null
    uci set firewall.@ipset[-1].name="${IPSET_NAME}"
    uci set firewall.@ipset[-1].family='ipv4'
    uci set firewall.@ipset[-1].match='dst_net'
    uci commit firewall
}

ensure_dnsmasq_core() {
    # Make sure dnsmasq is authoritative local resolver and does not use ISP DNS directly
    # It should use only our local DoH proxy on 127.0.0.1#5053

    log "Configuring dnsmasq to use DoH proxy only"

    uci -q set dhcp.@dnsmasq[0].noresolv='1'

    # Remove all existing 'server=' entries to avoid ISP/peer DNS leaks
    while uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#5053' 2>/dev/null; do :; done

    # Brutal but reliable: delete all list server entries by re-creating section values through batch logic
    # Since UCI doesn't provide "clear list" nicely for all cases, delete and re-add if possible
    # We do a best-effort:
    uci -q delete dhcp.@dnsmasq[0].server || true
    uci add_list dhcp.@dnsmasq[0].server="${DOH_LISTEN_ADDR}#${DOH_LISTEN_PORT}"

    # Optional hardening
    uci -q set dhcp.@dnsmasq[0].domainneeded='1'
    uci -q set dhcp.@dnsmasq[0].boguspriv='1'
    uci -q set dhcp.@dnsmasq[0].filterwin2k='0'
    uci -q set dhcp.@dnsmasq[0].localservice='1'

    uci commit dhcp
}

ensure_https_dns_proxy() {
    log "Configuring https-dns-proxy"

    # Delete existing sections with same name if present
    delete_all_matching_uci_sections https-dns-proxy "main" "."
    delete_all_matching_uci_sections https-dns-proxy "https-dns-proxy" "resolver_url="

    # Main section
    uci -q delete https-dns-proxy.config || true
    uci set https-dns-proxy.config='main'
    uci set https-dns-proxy.config.update_dnsmasq_config='-1'
    uci set https-dns-proxy.config.force_dns='0'
    # force_dns here intentionally off because we do firewall hijack ourselves
    # and we want dnsmasq to remain on :53, DoH proxy on :5053

    # Resolver section
    uci -q delete https-dns-proxy."$DOH_SECTION" || true
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

ensure_dns_hijack_firewall() {
    # Remove old duplicates
    delete_all_matching_uci_sections firewall redirect "name='Force-DNS-UDP'"
    delete_all_matching_uci_sections firewall redirect "name='Force-DNS-TCP'"

    log "Adding DNS hijack redirects (LAN -> router:53)"

    # UDP 53
    uci add firewall redirect >/dev/null
    uci set firewall.@redirect[-1].name='Force-DNS-UDP'
    uci set firewall.@redirect[-1].src='lan'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].dest_port='53'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].family='ipv4'

    # TCP 53
    uci add firewall redirect >/dev/null
    uci set firewall.@redirect[-1].name='Force-DNS-TCP'
    uci set firewall.@redirect[-1].src='lan'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].proto='tcp'
    uci set firewall.@redirect[-1].dest_port='53'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].family='ipv4'

    uci commit firewall
}

ensure_mark_rule() {
    # Remove duplicates
    delete_all_matching_uci_sections firewall rule "name='Mark-VPN-Domains'"

    log "Adding firewall MARK rule for ${IPSET_NAME}"

    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='Mark-VPN-Domains'
    uci set firewall.@rule[-1].src='lan'
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].family='ipv4'
    uci set firewall.@rule[-1].ipset="${IPSET_NAME} dest"
    uci set firewall.@rule[-1].target='MARK'
    uci set firewall.@rule[-1].set_mark="${MARK_HEX}"

    uci commit firewall
}

ensure_policy_routing() {
    log "Configuring policy routing for mark ${MARK_HEX} -> table ${ROUTE_TABLE_NAME}"

    # Wait for WG interface if needed
    if ! ip link show "$WG_IF" >/dev/null 2>&1; then
        warn "WireGuard interface ${WG_IF} not up yet. Restarting network."
        /etc/init.d/network restart
        sleep 3
    fi

    # Avoid duplicate rules
    if ! ip rule show | grep -q "fwmark ${MARK_HEX#0x}.*lookup ${ROUTE_TABLE_NAME}"; then
        ip rule add fwmark "$MARK_HEX" table "$ROUTE_TABLE_NAME" priority 10000 || true
    fi

    # Replace default route in table
    ip route replace default dev "$WG_IF" table "$ROUTE_TABLE_NAME"
}

download_domain_list() {
    log "Downloading russia_inside domains from ${DOMAINS_URL}"
    rm -f "$DOMAINS_RAW" "$DOMAINS_CLEAN"

    curl -fsSL "$DOMAINS_URL" -o "$DOMAINS_RAW"

    if [ ! -s "$DOMAINS_RAW" ]; then
        warn "Downloaded domain list is empty"
        exit 1
    fi

    # Clean:
    # - remove comments
    # - strip CR
    # - remove leading dots
    # - keep valid-ish domain names
    sed 's/\r$//' "$DOMAINS_RAW" \
        | sed 's/^[.]//' \
        | sed '/^[[:space:]]*#/d' \
        | sed '/^[[:space:]]*$/d' \
        | tr '[:upper:]' '[:lower:]' \
        | grep -E '^[a-z0-9._-]+\.[a-z0-9._-]+$' \
        | sed 's/[[:space:]]//g' \
        | sort -u > "$DOMAINS_CLEAN"

    if [ ! -s "$DOMAINS_CLEAN" ]; then
        warn "Cleaned domain list is empty after parsing"
        exit 1
    fi

    log "Domains prepared: $(wc -l < "$DOMAINS_CLEAN")"
}

apply_domains_to_dnsmasq_ipset() {
    log "Applying domains to dnsmasq ipset section"

    # Delete old dhcp ipset sections with same name
    delete_all_matching_uci_sections dhcp ipset "name='${IPSET_NAME}'"

    uci add dhcp ipset >/dev/null
    uci set dhcp.@ipset[-1].name="${IPSET_NAME}"

    # Add each domain
    while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        uci add_list dhcp.@ipset[-1].domain="$domain"
    done < "$DOMAINS_CLEAN"

    uci commit dhcp
}

restart_services() {
    log "Restarting dnsmasq and firewall"
    /etc/init.d/dnsmasq enable || true
    /etc/init.d/dnsmasq restart
    /etc/init.d/firewall enable || true
    /etc/init.d/firewall restart
}

show_summary() {
    echo
    echo "========================================"
    echo "Setup complete"
    echo "========================================"
    echo "WG interface:           ${WG_IF}"
    echo "Routing table:          ${ROUTE_TABLE_NAME} (${ROUTE_TABLE_ID})"
    echo "Mark:                   ${MARK_HEX}"
    echo "Domain set:             ${IPSET_NAME}"
    echo "Domain source:          ${DOMAINS_URL}"
    echo "DoH local listener:     ${DOH_LISTEN_ADDR}:${DOH_LISTEN_PORT}"
    echo "LAN DNS hijack on:      ${LAN_IF} TCP/UDP 53 -> router:53"
    echo
    echo "Check these:"
    echo "  logread | grep https-dns-proxy"
    echo "  netstat -lntup | grep 5053"
    echo "  nslookup example.com 127.0.0.1"
    echo "  ip rule show"
    echo "  ip route show table ${ROUTE_TABLE_NAME}"
    echo "  nft list ruleset | grep -i dns"
    echo "========================================"
    echo
}

# ---------- main ----------

log "Ensuring required packages"
ensure_pkg dnsmasq-full
ensure_pkg curl
ensure_pkg ca-bundle
ensure_pkg wireguard-tools
ensure_pkg kmod-wireguard
ensure_pkg https-dns-proxy

# firewall4 is default in modern OpenWrt; no package install here

ensure_rt_table
ensure_wg_config
ensure_wg_firewall_zone
ensure_ipset_section
ensure_https_dns_proxy
ensure_dnsmasq_core
ensure_dns_hijack_firewall
ensure_mark_rule
download_domain_list
apply_domains_to_dnsmasq_ipset
restart_services
ensure_policy_routing
show_summary
