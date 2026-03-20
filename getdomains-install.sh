#!/bin/sh
set -e

echo "Starting domain routing setup for Alpine-based OpenWrt..."
echo "Checking system version..."
cat /etc/os-release

# Ensure basic tools
echo "Installing curl..."
apk update
apk add --no-cache curl nano

# Tunnel selection
echo "Select a tunnel:"
echo "1) WireGuard"
echo "2) OpenVPN"
echo "3) Sing-box"
echo "4) tun2socks"
echo "5) wgForYoutube"
echo "6) Amnezia WireGuard"
echo "7) Amnezia WireGuard For Youtube"
echo "8) Skip"
read -p "Enter number [1-8]: " TUNNEL

if [ "$TUNNEL" = "1" ]; then
    echo "Configuring WireGuard..."
    apk add --no-cache wireguard-tools iproute2

    read -p "Enter private key: " WG_PRIV
    read -p "Enter internal IP with subnet (e.g. 10.8.0.3/24): " WG_IP
    read -p "Enter public key of peer: " WG_PUB
    read -p "Enter preshared key (or leave blank): " WG_PSK
    read -p "Enter endpoint host (IP or domain): " WG_HOST
    read -p "Enter endpoint port [51820]: " WG_PORT
    WG_PORT=${WG_PORT:-51820}

    mkdir -p /etc/wireguard
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $WG_PRIV
Address = $WG_IP
ListenPort = 51820

[Peer]
PublicKey = $WG_PUB
PresharedKey = $WG_PSK
Endpoint = $WG_HOST:$WG_PORT
AllowedIPs = 0.0.0.0/0, ::/0
EOF

    wg-quick up wg0 || echo "WireGuard started with errors"
fi

# Configure dnsmasq
echo "Installing dnsmasq..."
apk add --no-cache dnsmasq

# Configure DNSCrypt2 or Stubby
echo "Configure DNS resolver:"
echo "1) No [Default]"
echo "2) DNSCrypt2"
echo "3) Stubby"
read -p "Choose option [1-3]: " DNS_CHOICE

if [ "$DNS_CHOICE" = "2" ]; then
    apk add --no-cache dnscrypt-proxy
    rc-service dnscrypt-proxy restart || systemctl restart dnscrypt-proxy
fi

# Country selection (for domain lists)
echo "Choose your country for domain rules:"
echo "1) Russia inside"
echo "2) Russia outside"
echo "3) Ukraine"
echo "4) Skip"
read -p "Enter number [1-4]: " COUNTRY

# Create updater script
cat > /etc/init.d/getdomains <<'EOF'
#!/bin/sh
start() {
    echo "Running domain updater..."
    curl -s -o /tmp/domains.lst "https://example.com/domains.lst"
    if [ -f /tmp/domains.lst ]; then
        cp /tmp/domains.lst /etc/dnsmasq.d/domains.lst
        rc-service dnsmasq restart || systemctl restart dnsmasq
    else
        echo "Warning: domains list not found"
    fi
}
EOF

chmod +x /etc/init.d/getdomains
/etc/init.d/getdomains start

echo "Restarting network..."
rc-service network restart || systemctl restart network

echo "Setup complete."
