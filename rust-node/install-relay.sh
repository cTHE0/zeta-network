#!/bin/bash
# Zeta Network - Installation Relais (1 commande)
# Usage: git clone https://github.com/cTHE0/zeta-network.git && cd zeta-network/rust-node && sudo ./install-relay.sh [DOMAINE]
#
# Sans domaine : Le relais fonctionne en local (pour tests)
# Avec domaine : HTTPS automatique via Let's Encrypt
#
# Exemple: sudo ./install-relay.sh relay.monsite.com

set -e
cd "$(dirname "$0")"

DOMAIN=$1
INSTALL_DIR="/opt/zeta-relay"

echo "🚀 Installation Zeta Network Relay"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$EUID" -ne 0 ]; then
    echo "❌ Lancez avec sudo : sudo ./install-relay.sh [DOMAINE]"
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# Arrêter les services existants
systemctl stop zeta-relay caddy 2>/dev/null || true
sleep 2

# === 1. INSTALLER LE BINAIRE ZETA ===
echo ""
echo "📦 Étape 1/3 : Installation du relais..."

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ZETA_BIN="zeta-relay-linux-x86_64" ;;
    aarch64|arm64) ZETA_BIN="zeta-relay-linux-arm64" ;;
    *) ZETA_BIN="" ;;
esac

DOWNLOADED=false
if [ -n "$ZETA_BIN" ]; then
    echo "   📥 Téléchargement..."
    if curl -fsSL "https://github.com/cTHE0/zeta-network/releases/latest/download/$ZETA_BIN" -o "$INSTALL_DIR/zeta-relay" 2>/dev/null; then
        chmod +x "$INSTALL_DIR/zeta-relay"
        DOWNLOADED=true
        echo "   ✅ Binaire téléchargé"
    fi
fi

if [ "$DOWNLOADED" = false ]; then
    echo "   🔨 Compilation (~3 min)..."
    if ! command -v cargo &> /dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
    cargo build --release
    cp target/release/zeta-relay "$INSTALL_DIR/"
    echo "   ✅ Compilé"
fi

# === 2. INSTALLER CADDY (HTTPS automatique) ===
echo ""
echo "🔒 Étape 2/3 : Configuration HTTPS..."

if ! command -v caddy &> /dev/null; then
    echo "   📥 Installation de Caddy..."
    apt-get update -qq
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq caddy
fi
echo "   ✅ Caddy installé"

# === 3. CONFIGURER LES SERVICES ===
echo ""
echo "⚙️ Étape 3/3 : Démarrage des services..."

# Service Zeta Relay
cat > /etc/systemd/system/zeta-relay.service << 'EOF'
[Unit]
Description=Zeta Network Relay
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/zeta-relay
ExecStart=/opt/zeta-relay/zeta-relay --relay --web-port 3030
Restart=always
RestartSec=5
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
EOF

# Configuration Caddy
if [ -n "$DOMAIN" ]; then
    # Avec domaine = HTTPS automatique Let's Encrypt
    cat > /etc/caddy/Caddyfile << EOF
$DOMAIN {
    reverse_proxy localhost:3030
}
EOF
    echo "   🌐 Domaine configuré: $DOMAIN"
else
    # Sans domaine = HTTP local seulement
    cat > /etc/caddy/Caddyfile << 'EOF'
:80 {
    reverse_proxy localhost:3030
}
EOF
    echo "   ⚠️ Pas de domaine - mode local uniquement"
fi

# Ouvrir les ports
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    ufw allow 4001/tcp >/dev/null 2>&1 || true
fi

systemctl daemon-reload
systemctl enable zeta-relay caddy 2>/dev/null || true
systemctl restart zeta-relay
sleep 2
systemctl restart caddy

# Récupérer les infos
sleep 3
PEER_ID=$(curl -s http://localhost:3030/api/network 2>/dev/null | grep -oP '"local_peer_id":"\K[^"]+' || echo "...")
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ RELAIS OPÉRATIONNEL !"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -n "$DOMAIN" ]; then
    echo "🌐 URL publique : https://$DOMAIN"
    echo "🔌 WebSocket    : wss://$DOMAIN/ws"
    echo ""
    echo "📋 Ajoutez ce relais à zetanetwork.org :"
    echo ""
    echo "   {\"name\": \"Relais\", \"ws\": \"wss://$DOMAIN/ws\", \"api\": \"https://$DOMAIN\"}"
    
    # Sauvegarder config
    echo "$DOMAIN" > "$INSTALL_DIR/domain.txt"
    echo "wss://$DOMAIN/ws" > "$INSTALL_DIR/ws-url.txt"
else
    echo "⚠️  HTTPS non activé (pas de domaine)"
    echo ""
    echo "🔧 Pour activer HTTPS, relancez avec un domaine :"
    echo "   sudo ./install-relay.sh relay.votredomaine.com"
    echo ""
    echo "   Assurez-vous que le DNS pointe vers : $PUBLIC_IP"
    echo ""
    echo "📡 Accès local : http://$PUBLIC_IP"
fi

echo ""
echo "🔑 Peer ID : $PEER_ID"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📝 Commandes utiles :"
echo "   sudo systemctl status zeta-relay   # État du relais"
echo "   sudo systemctl status caddy        # État HTTPS"
echo "   sudo journalctl -u zeta-relay -f   # Logs"
