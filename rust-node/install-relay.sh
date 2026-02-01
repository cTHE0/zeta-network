#!/bin/bash
# Zeta Network - Installation Relais
# Usage: git clone https://github.com/cTHE0/zeta-network.git && cd zeta-network/rust-node && sudo ./install-relay.sh

set -e
cd "$(dirname "$0")"

INSTALL_DIR="/opt/zeta-relay"

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   🚀 Zeta Network - Installation     ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "❌ Lancez avec : sudo ./install-relay.sh"
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# Arrêter les services existants
systemctl stop zeta-relay zeta-tunnel 2>/dev/null || true
sleep 1

# === ÉTAPE 1 : BINAIRE ===
echo "📦 [1/3] Installation du relais..."

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) BIN_URL="zeta-relay-linux-x86_64" ;;
    aarch64|arm64) BIN_URL="zeta-relay-linux-arm64" ;;
    *) BIN_URL="" ;;
esac

if [ -n "$BIN_URL" ]; then
    curl -fsSL "https://github.com/cTHE0/zeta-network/releases/latest/download/$BIN_URL" -o "$INSTALL_DIR/zeta-relay" 2>/dev/null && chmod +x "$INSTALL_DIR/zeta-relay" && echo "   ✅ Téléchargé" || {
        echo "   🔨 Compilation..."
        command -v cargo &>/dev/null || { curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && source "$HOME/.cargo/env"; }
        cargo build --release && cp target/release/zeta-relay "$INSTALL_DIR/" && echo "   ✅ Compilé"
    }
else
    echo "   🔨 Compilation..."
    command -v cargo &>/dev/null || { curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && source "$HOME/.cargo/env"; }
    cargo build --release && cp target/release/zeta-relay "$INSTALL_DIR/"
fi

# === ÉTAPE 2 : CLOUDFLARED ===
echo ""
echo "🔒 [2/3] Configuration HTTPS (Cloudflare Tunnel)..."

if ! command -v cloudflared &>/dev/null; then
    case "$ARCH" in
        x86_64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        aarch64|arm64) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        armv7l) CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
    esac
    curl -fsSL "$CF_URL" -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
fi
echo "   ✅ Cloudflare Tunnel prêt"

# === ÉTAPE 3 : SERVICES ===
echo ""
echo "⚙️  [3/3] Démarrage des services..."

# Service relais
cat > /etc/systemd/system/zeta-relay.service << 'EOF'
[Unit]
Description=Zeta Network Relay
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/zeta-relay
ExecStart=/opt/zeta-relay/zeta-relay --relay --web-port 3030
Restart=always
RestartSec=3
Environment=RUST_LOG=info
[Install]
WantedBy=multi-user.target
EOF

# Service tunnel (capture l'URL au démarrage)
cat > /etc/systemd/system/zeta-tunnel.service << 'EOF'
[Unit]
Description=Zeta HTTPS Tunnel
After=zeta-relay.service
Requires=zeta-relay.service
[Service]
Type=simple
ExecStart=/bin/bash -c '/usr/local/bin/cloudflared tunnel --url http://localhost:3030 2>&1 | tee /opt/zeta-relay/tunnel.log'
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

# Ouvrir les ports
command -v ufw &>/dev/null && { ufw allow 4001/tcp &>/dev/null || true; }

systemctl daemon-reload
systemctl enable zeta-relay zeta-tunnel &>/dev/null
systemctl restart zeta-relay
sleep 2
systemctl restart zeta-tunnel

# Attendre l'URL du tunnel
echo ""
echo "   ⏳ Attente du tunnel HTTPS..."
TUNNEL_URL=""
for i in {1..30}; do
    if [ -f /opt/zeta-relay/tunnel.log ]; then
        TUNNEL_URL=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /opt/zeta-relay/tunnel.log 2>/dev/null | head -1)
        [ -n "$TUNNEL_URL" ] && break
    fi
    sleep 1
done

# Récupérer infos
PEER_ID=$(curl -s http://localhost:3030/api/network 2>/dev/null | grep -oP '"local_peer_id":"\K[^"]+' || echo "inconnu")

echo ""
echo "  ╔═══════════════════════════════════════════════════════════════╗"
echo "  ║                    ✅ RELAIS OPÉRATIONNEL                     ║"
echo "  ╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ -n "$TUNNEL_URL" ]; then
    WS_URL="${TUNNEL_URL/https:/wss:}/ws"
    echo "$TUNNEL_URL" > "$INSTALL_DIR/url.txt"
    echo "$WS_URL" > "$INSTALL_DIR/ws-url.txt"
    
    echo "  🌐 URL HTTPS  : $TUNNEL_URL"
    echo "  🔌 WebSocket  : $WS_URL"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │ 📋 COPIEZ CETTE LIGNE pour l'ajouter au réseau :           │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  {\"name\": \"Mon-Relais\", \"ws\": \"$WS_URL\", \"api\": \"$TUNNEL_URL\"}"
    echo ""
else
    echo "  ⚠️  Tunnel pas encore prêt. Vérifiez dans 1 minute :"
    echo "     cat /opt/zeta-relay/url.txt"
    echo ""
    echo "  Ou relancez : sudo systemctl restart zeta-tunnel"
fi

echo "  🔑 Peer ID : $PEER_ID"
echo ""
echo "  ─────────────────────────────────────────────────────────────────"
echo "  📝 Commandes utiles :"
echo "     systemctl status zeta-relay    # État du relais"
echo "     systemctl status zeta-tunnel   # État du tunnel"
echo "     cat /opt/zeta-relay/ws-url.txt # URL WebSocket"
echo "     journalctl -u zeta-relay -f    # Logs"
echo ""
