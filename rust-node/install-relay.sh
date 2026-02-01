#!/bin/bash
# Zeta Network - Installation Relais (1 commande)
# Usage: git clone https://github.com/cTHE0/zeta-network.git && cd zeta-network/rust-node && sudo ./install-relay.sh

set -e
cd "$(dirname "$0")"

echo "🚀 Installation Zeta Network Relay"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Vérifier root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Lancez avec sudo : sudo ./install-relay.sh"
    exit 1
fi

INSTALL_DIR="/opt/zeta-relay"
mkdir -p "$INSTALL_DIR"

# Arrêter les services existants si présents
systemctl stop zeta-relay zeta-tunnel 2>/dev/null || true

# === 1. INSTALLER LE BINAIRE ZETA ===
echo ""
echo "📦 Étape 1/3 : Installation du relais..."

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) BINARY="zeta-relay-linux-x86_64" ;;
    aarch64|arm64) BINARY="zeta-relay-linux-arm64" ;;
    *) BINARY="" ;;
esac

DOWNLOADED=false
if [ -n "$BINARY" ]; then
    echo "   📥 Téléchargement du binaire..."
    if curl -fsSL "https://github.com/cTHE0/zeta-network/releases/latest/download/$BINARY" -o "$INSTALL_DIR/zeta-relay" 2>/dev/null; then
        chmod +x "$INSTALL_DIR/zeta-relay"
        DOWNLOADED=true
        echo "   ✅ Binaire téléchargé"
    fi
fi

if [ "$DOWNLOADED" = false ]; then
    echo "   🔨 Compilation (première fois, ~3 min)..."
    
    if ! command -v cargo &> /dev/null; then
        echo "   📦 Installation de Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
    
    cargo build --release
    cp target/release/zeta-relay "$INSTALL_DIR/"
    echo "   ✅ Compilation terminée"
fi

# === 2. INSTALLER CLOUDFLARE TUNNEL (pour HTTPS/WSS automatique) ===
echo ""
echo "🔒 Étape 2/3 : Configuration HTTPS automatique..."

if ! command -v cloudflared &> /dev/null; then
    echo "   📥 Installation de Cloudflare Tunnel..."
    
    case "$ARCH" in
        x86_64)
            curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
            ;;
        aarch64|arm64)
            curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o /usr/local/bin/cloudflared
            ;;
        armv7l)
            curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o /usr/local/bin/cloudflared
            ;;
        *)
            echo "   ⚠️ Architecture non supportée pour cloudflared"
            ;;
    esac
    
    chmod +x /usr/local/bin/cloudflared 2>/dev/null || true
fi

if command -v cloudflared &> /dev/null; then
    echo "   ✅ Cloudflare Tunnel installé"
else
    echo "   ⚠️ Cloudflare Tunnel non disponible"
fi

# === 3. CRÉER LES SERVICES SYSTEMD ===
echo ""
echo "⚙️ Étape 3/3 : Configuration des services..."

# Service pour le relais Zeta
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

# Service pour le tunnel Cloudflare (HTTPS automatique)
cat > /etc/systemd/system/zeta-tunnel.service << 'EOF'
[Unit]
Description=Zeta Network HTTPS Tunnel
After=network.target zeta-relay.service
Requires=zeta-relay.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:3030 --logfile /opt/zeta-relay/tunnel.log
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zeta-relay zeta-tunnel 2>/dev/null || true
systemctl restart zeta-relay

# Attendre que le relais démarre
sleep 3

# Démarrer le tunnel et récupérer l'URL
echo ""
echo "🌐 Démarrage du tunnel HTTPS..."

# Supprimer l'ancien log
rm -f /opt/zeta-relay/tunnel.log

systemctl restart zeta-tunnel
sleep 8

# Récupérer l'URL du tunnel
TUNNEL_URL=""
for i in {1..15}; do
    if [ -f /opt/zeta-relay/tunnel.log ]; then
        TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /opt/zeta-relay/tunnel.log 2>/dev/null | head -1)
        if [ -n "$TUNNEL_URL" ]; then
            break
        fi
    fi
    sleep 2
done

# Récupérer les infos du relais
PEER_ID=$(curl -s http://localhost:3030/api/network 2>/dev/null | grep -oP '"local_peer_id":"\K[^"]+' || echo "...")
LOCAL_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

# Sauvegarder l'URL du tunnel
if [ -n "$TUNNEL_URL" ]; then
    echo "$TUNNEL_URL" > /opt/zeta-relay/tunnel-url.txt
fi

# Ouvrir les ports
if command -v ufw &> /dev/null; then
    ufw allow 4001/tcp >/dev/null 2>&1 || true
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ RELAIS OPÉRATIONNEL !"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -n "$TUNNEL_URL" ]; then
    WS_URL="${TUNNEL_URL/https:/wss:}/ws"
    echo "🌐 URL publique (HTTPS) : $TUNNEL_URL"
    echo "🔌 WebSocket (WSS)      : $WS_URL"
    echo ""
    echo "📋 Pour ajouter ce relais au réseau, envoyez cette ligne :"
    echo ""
    echo "   {\"name\": \"Relais-$PEER_ID\", \"ws\": \"$WS_URL\", \"api\": \"$TUNNEL_URL\"}"
    echo ""
else
    echo "⚠️ Tunnel HTTPS non disponible."
    echo ""
    echo "   Le relais fonctionne mais n'est accessible qu'en local."
    echo "   Pour réessayer : sudo systemctl restart zeta-tunnel"
    echo "   Voir les logs  : cat /opt/zeta-relay/tunnel.log"
fi

echo "🔑 Peer ID : $PEER_ID"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📝 Commandes utiles :"
echo "   sudo systemctl status zeta-relay    # État du relais"
echo "   sudo systemctl status zeta-tunnel   # État du tunnel"
echo "   cat /opt/zeta-relay/tunnel-url.txt  # Voir l'URL HTTPS"
echo "   sudo journalctl -u zeta-relay -f    # Logs temps réel"
