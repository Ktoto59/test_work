#!/bin/sh

set -eu

BASE_DIR="/etc/hivpn"
BIN_SCRIPT="/usr/bin/getdomains-wg"
INIT_SCRIPT="/etc/init.d/getdomains-wg"
HOTPLUG_SCRIPT="/etc/hotplug.d/iface/95-getdomains-wg"
DOMAINS_FILE="$BASE_DIR/domains.lst"
CRON_FILE="/etc/crontabs/root"

WG_IF="wg0"
NFT_FAMILY="inet"
NFT_TABLE="fw4"
NFT_SET4="vpn_domains"
FWMARK_HEX="0x1"
ROUTE_TABLE="100"
ROUTE_PRIORITY="10000"

GETDOMAINS_URL="https://raw.githubusercontent.com/Ktoto59/test_work/refs/heads/main/getdomains-install.sh"

GREEN="\033[32;1m"
RED="\033[31;1m"
BLUE="\033[34;1m"
YELLOW="\033[33;1m"
RESET="\033[0m"

ok() {
    printf "${GREEN}[✓] %s${RESET}\n" "$1"
}

warn() {
    printf "${YELLOW}[!] %s${RESET}\n" "$1"
}

err() {
    printf "${RED}[x] %s${RESET}\n" "$1"
}

info() {
    printf "${BLUE}[*] %s${RESET}\n" "$1"
}

die() {
    err "$1"
    exit 1
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

ensure_cmd() {
    cmd_exists "$1" || die "Команда не найдена: $1"
}

get_wg_uci_iface() {
    uci show network 2>/dev/null | grep "=interface" | cut -d. -f2 | cut -d= -f1 | while read -r s; do
        proto="$(uci -q get network."$s".proto || true)"
        device="$(uci -q get network."$s".device || true)"
        ifname="$(uci -q get network."$s".ifname || true)"
        if [ "$proto" = "wireguard" ]; then
            echo "$s"
            return 0
        fi
        if [ "$device" = "$WG_IF" ] || [ "$ifname" = "$WG_IF" ]; then
            echo "$s"
            return 0
        fi
    done
    return 1
}

check_prereqs() {
    ensure_cmd ip
    ensure_cmd nft
    ensure_cmd nslookup
    ensure_cmd uci
    ensure_cmd grep
    ensure_cmd awk
    ensure_cmd sed
    ensure_cmd sort
    ensure_cmd logger

    if ! cmd_exists curl; then
        warn "curl не найден, ставлю..."
        opkg update
        opkg install curl || die "Не удалось установить curl"
    fi

    if ! ip link show "$WG_IF" >/dev/null 2>&1; then
        die "Интерфейс $WG_IF не найден. Проверь имя WG интерфейса."
    fi

    if ip link show "$WG_IF" | grep -q "UP"; then
        ok "Интерфейс $WG_IF найден и поднят"
    else
        warn "Интерфейс $WG_IF найден, но сейчас не UP. Продолжаем."
    fi

    WG_UCI_IFACE="$(get_wg_uci_iface || true)"
    if [ -n "${WG_UCI_IFACE:-}" ]; then
        RAI="$(uci -q get network."$WG_UCI_IFACE".route_allowed_ips || echo 0)"
        if [ "$RAI" = "1" ]; then
            die "У интерфейса network.$WG_UCI_IFACE включен route_allowed_ips=1. Это ломает selective routing. Выключи: uci set network.$WG_UCI_IFACE.route_allowed_ips='0'; uci commit network; service network restart"
        else
            ok "route_allowed_ips=0 (или не задан) для network.$WG_UCI_IFACE"
        fi
    else
        warn "Не удалось однозначно определить UCI-секцию WireGuard. Проверь route_allowed_ips вручную."
    fi
}

create_dirs_and_files() {
    mkdir -p "$BASE_DIR"

    if [ ! -f "$DOMAINS_FILE" ]; then
        cat > "$DOMAINS_FILE" << 'EOF'
instagram.com
facebook.com
fbcdn.net
cdninstagram.com
whatsapp.com
whatsapp.net
youtube.com
googlevideo.com
ytimg.com
youtu.be
EOF
        ok "Создан список доменов: $DOMAINS_FILE"
    else
        ok "Список доменов уже существует: $DOMAINS_FILE"
    fi
}

create_getdomains_script() {
    cat > "$BIN_SCRIPT" << 'EOF'
#!/bin/sh

DOMAINS_FILE="/etc/hivpn/domains.lst"
NFT_FAMILY="inet"
NFT_TABLE="fw4"
NFT_SET4="vpn_domains"

WG_IF="wg0"
FWMARK_HEX="0x1"
ROUTE_TABLE="100"
ROUTE_PRIORITY="10000"

TMP_FILE="/tmp/getdomains-wg.ips"
LOCK_FILE="/var/run/getdomains-wg.lock"
LOG_TAG="getdomains-wg"

log() {
    logger -t "$LOG_TAG" "$*"
    echo "$LOG_TAG: $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_cmd() {
    command_exists "$1" || fail "command not found: $1"
}

resolve_domain_ipv4() {
    local domain="$1"

    nslookup "$domain" 127.0.0.1 2>/dev/null \
        | awk '/^Address [0-9]+: / {print $3} /^Address: / {print $2}' \
        | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        | sort -u
}

ensure_nft_set() {
    nft list set "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SET4" >/dev/null 2>&1 && return 0

    nft add set "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SET4" "{ type ipv4_addr; flags interval; comment \"WG domain routing\"; }" \
        || fail "failed to create nft set $NFT_SET4"
}

flush_nft_set() {
    nft flush set "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SET4" >/dev/null 2>&1 \
        || fail "failed to flush nft set $NFT_SET4"
}

load_ips_to_nft() {
    local count
    count="$(wc -l < "$TMP_FILE" | tr -d ' ')"
    [ -n "$count" ] || count=0

    flush_nft_set

    if [ "$count" -eq 0 ]; then
        log "no IPs resolved, nft set left empty"
        return 0
    fi

    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        nft add element "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SET4" "{ $ip }" \
            || log "failed to add IP $ip"
    done < "$TMP_FILE"

    log "loaded $count IPs into nft set $NFT_SET4"
}

ensure_mark_rules() {
    nft list chain inet fw4 mangle_prerouting >/dev/null 2>&1 || fail "chain inet fw4 mangle_prerouting not found"
    nft list chain inet fw4 mangle_output >/dev/null 2>&1 || fail "chain inet fw4 mangle_output not found"

    nft list chain inet fw4 mangle_prerouting 2>/dev/null | grep -Fq 'comment "wg-domain-routing-prerouting"' || \
        nft insert rule inet fw4 mangle_prerouting ip daddr @"$NFT_SET4" meta mark set "$FWMARK_HEX" comment "wg-domain-routing-prerouting" || \
        fail "failed to add prerouting mark rule"

    nft list chain inet fw4 mangle_output 2>/dev/null | grep -Fq 'comment "wg-domain-routing-output"' || \
        nft insert rule inet fw4 mangle_output ip daddr @"$NFT_SET4" meta mark set "$FWMARK_HEX" comment "wg-domain-routing-output" || \
        fail "failed to add output mark rule"
}

ensure_ip_rule() {
    ip rule show | grep -q "fwmark 0x1 lookup $ROUTE_TABLE" && return 0
    ip rule add fwmark "$FWMARK_HEX" table "$ROUTE_TABLE" priority "$ROUTE_PRIORITY" 2>/dev/null || true
}

ensure_route_table() {
    ip route show table "$ROUTE_TABLE" | grep -q "^default dev $WG_IF" && return 0
    ip route del default table "$ROUTE_TABLE" 2>/dev/null || true
    ip route add default dev "$WG_IF" table "$ROUTE_TABLE" || fail "failed to add default route via $WG_IF"
}

resolve_all_domains() {
    [ -f "$DOMAINS_FILE" ] || fail "domains file not found: $DOMAINS_FILE"

    : > "$TMP_FILE"

    while IFS= read -r domain; do
        domain="$(echo "$domain" | sed 's/#.*$//' | tr -d '\r' | xargs)"
        [ -n "$domain" ] || continue

        log "resolving $domain"
        resolve_domain_ipv4 "$domain" >> "$TMP_FILE"
    done < "$DOMAINS_FILE"

    sort -u "$TMP_FILE" -o "$TMP_FILE"
}

lock() {
    if [ -e "$LOCK_FILE" ]; then
        oldpid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
        if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
            fail "another instance already running (pid $oldpid)"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE" "$TMP_FILE"' EXIT INT TERM
}

start_main() {
    lock

    require_cmd nft
    require_cmd ip
    require_cmd nslookup

    ensure_nft_set
    ensure_mark_rules
    ensure_ip_rule
    ensure_route_table
    resolve_all_domains
    load_ips_to_nft

    log "done"
}

flush_main() {
    nft list set "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SET4" >/dev/null 2>&1 && nft flush set "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SET4" >/dev/null 2>&1
    log "nft set flushed"
}

status_main() {
    echo "=== nft set ==="
    nft list set "$NFT_FAMILY" "$NFT_TABLE" "$NFT_SET4" 2>/dev/null || echo "set not found"

    echo
    echo "=== nft mark rules ==="
    nft list chain inet fw4 mangle_prerouting 2>/dev/null | grep "wg-domain-routing" || true
    nft list chain inet fw4 mangle_output 2>/dev/null | grep "wg-domain-routing" || true

    echo
    echo "=== ip rule ==="
    ip rule show | grep "lookup $ROUTE_TABLE" || echo "ip rule not found"

    echo
    echo "=== table $ROUTE_TABLE ==="
    ip route show table "$ROUTE_TABLE" || echo "route table empty"
}

case "$1" in
    start|reload|restart)
        start_main
        ;;
    flush)
        flush_main
        ;;
    status)
        status_main
        ;;
    *)
        echo "Usage: $0 {start|reload|restart|flush|status}"
        exit 1
        ;;
esac
EOF

    chmod +x "$BIN_SCRIPT"
    ok "Создан $BIN_SCRIPT"
}

create_init_script() {
    cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
    /usr/bin/getdomains-wg start
}

reload_service() {
    /usr/bin/getdomains-wg reload
}

service_triggers() {
    procd_add_reload_trigger network firewall
}
EOF

    chmod +x "$INIT_SCRIPT"
    /etc/init.d/getdomains-wg enable
    ok "Создан и включен $INIT_SCRIPT"
}

create_hotplug_script() {
    mkdir -p /etc/hotplug.d/iface

    cat > "$HOTPLUG_SCRIPT" << 'EOF'
#!/bin/sh

[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wg0" ] || exit 0

logger -t getdomains-wg-hotplug "wg0 is up, refreshing domain routes"
/usr/bin/getdomains-wg reload
EOF

    chmod +x "$HOTPLUG_SCRIPT"
    ok "Создан $HOTPLUG_SCRIPT"
}

setup_cron() {
    grep -q "/usr/bin/getdomains-wg reload" "$CRON_FILE" 2>/dev/null || echo "*/30 * * * * /usr/bin/getdomains-wg reload >/dev/null 2>&1" >> "$CRON_FILE"
    /etc/init.d/cron restart
    ok "Добавлен cron на обновление каждые 30 минут"
}

ensure_firewall_ready() {
    /etc/init.d/firewall enabled >/dev/null 2>&1 || true
    /etc/init.d/firewall restart
    ok "fw4/firewall перезапущен"
}

run_initial_start() {
    /etc/init.d/getdomains-wg start || die "Не удалось запустить getdomains-wg"
    ok "Первичный запуск выполнен"
}

show_status() {
    echo
    info "Проверка статуса:"
    /usr/bin/getdomains-wg status || true
}

main() {
    info "Установка selective domain routing для WireGuard на OpenWrt 25.12.1+"
    check_prereqs
    create_dirs_and_files
    create_getdomains_script
    create_init_script
    create_hotplug_script
    setup_cron
    ensure_firewall_ready
    run_initial_start
    show_status

    echo
    ok "Готово."
    echo
    echo "Файл доменов: $DOMAINS_FILE"
    echo "Редактировать список доменов:"
    echo "  vi $DOMAINS_FILE"
    echo
    echo "Обновить вручную:"
    echo "  /usr/bin/getdomains-wg reload"
    echo
    echo "Статус:"
    echo "  /usr/bin/getdomains-wg status"
    echo
    echo "Если WG интерфейс НЕ wg0 — правь WG_IF в:"
    echo "  $BIN_SCRIPT"
    echo "  $HOTPLUG_SCRIPT"
}

main "$@"
