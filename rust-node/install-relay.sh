#!/bin/bash
# Zeta Network - Installation Relais
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

# Essayer de télécharger le binaire pré-compilé
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) BINARY="zeta-relay-linux-x86_64" ;;
    aarch64|arm64) BINARY="zeta-relay-linux-arm64" ;;
    *) BINARY="" ;;
esac

DOWNLOADED=false
if [ -n "$BINARY" ]; then
    echo "📥 Téléchargement du binaire..."
    if curl -fsSL "https://github.com/cTHE0/zeta-network/releases/latest/download/$BINARY" -o "$INSTALL_DIR/zeta-relay" 2>/dev/null; then
        chmod +x "$INSTALL_DIR/zeta-relay"
        DOWNLOADED=true
        echo "✅ Binaire téléchargé"
    fi
fi

# Si téléchargement échoué, compiler
if [ "$DOWNLOADED" = false ]; then
    echo "🔨 Compilation (première fois, ~2 min)..."
    
    # Installer Rust si nécessaire
    if ! command -v cargo &> /dev/null; then
        echo "📦 Installation de Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
    
    cargo build --release
    cp target/release/zeta-relay "$INSTALL_DIR/"
    echo "✅ Compilation terminée"
fi

# Service systemd
echo "⚙️  Configuration du service..."
cat > /etc/systemd/system/zeta-relay.service << 'SVCEOF'
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
SVCEOF

systemctl daemon-reload
systemctl enable zeta-relay
systemctl restart zeta-relay

# Ouvrir les ports (UFW si présent)
if command -v ufw &> /dev/null; then
    ufw allow 4001/tcp >/dev/null 2>&1 || true
    ufw allow 3030/tcp >/dev/null 2>&1 || true
fi

sleep 3

# Récupérer les infos
IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
PEER_ID=$(curl -s http://localhost:3030/api/network 2>/dev/null | grep -oP '"local_peer_id":"\K[^"]+' || echo "...")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ RELAIS OPÉRATIONNEL !"
echo ""
echo "📋 Adresse bootstrap (à partager) :"
echo "   /ip4/$IP/tcp/4001/p2p/$PEER_ID"
echo ""
echo "🌐 Interface web locale : http://$IP:3030"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📝 Commandes utiles :"
echo "   sudo systemctl status zeta-relay"
echo "   sudo journalctl -u zeta-relay -f"
