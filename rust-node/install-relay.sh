#!/bin/bash
# Zeta Network - Installation Relais
# Usage: sudo ./install-relay.sh

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
systemctl stop zeta-relay 2>/dev/null || true
sleep 1

# === BINAIRE ===
echo "📦 Installation du relais..."

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

# === SERVICE ===
echo ""
echo "⚙️  Configuration du service..."

cat > /etc/systemd/system/zeta-relay.service << 'SERVICEEOF'
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
SERVICEEOF

command -v ufw &>/dev/null && { ufw allow 3030/tcp &>/dev/null; ufw allow 4001/tcp &>/dev/null; } || true

systemctl daemon-reload
systemctl enable zeta-relay
systemctl start zeta-relay

sleep 2

# === RÉSULTAT ===
IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "===================================="
echo "✅ RELAIS ZETA INSTALLÉ !"
echo "===================================="
echo ""
echo "🌍 Interface web : http://$IP:3030"
echo ""
echo "Partagez cette URL pour que d'autres se connectent !"
echo ""
echo "📋 Commandes utiles :"
echo "   systemctl status zeta-relay"
echo "   journalctl -u zeta-relay -f"
echo ""
