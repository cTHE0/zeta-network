#!/bin/bash
# Zeta Network - Installation/Mise à jour Relais
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

# Stopper le service si existant
systemctl stop zeta-relay 2>/dev/null || true
sleep 1

# === INSTALLER RUST SI NÉCESSAIRE ===
if ! command -v cargo &>/dev/null; then
    echo "📦 Installation de Rust..."
    sudo -u $(logname) bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
    source /home/$(logname)/.cargo/env
    export PATH="/home/$(logname)/.cargo/bin:$PATH"
fi

# Charger cargo pour l'utilisateur actuel
CARGO_PATH="/home/$(logname)/.cargo/bin/cargo"
if [ ! -f "$CARGO_PATH" ]; then
    CARGO_PATH=$(which cargo 2>/dev/null || echo "")
fi

if [ -z "$CARGO_PATH" ] || [ ! -f "$CARGO_PATH" ]; then
    echo "❌ Cargo non trouvé. Installez Rust manuellement:"
    echo "   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
fi

# === COMPILER ===
echo "🔨 Compilation du relais..."
sudo -u $(logname) bash -c "cd $(pwd) && $CARGO_PATH build --release"

if [ ! -f "target/release/zeta-relay" ]; then
    echo "❌ Erreur de compilation"
    exit 1
fi
echo "   ✅ Compilation réussie"

# === INSTALLER ===
echo ""
echo "📦 Installation..."
mkdir -p "$INSTALL_DIR"

cp target/release/zeta-relay "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/zeta-relay"
echo "   ✅ Binaire installé"

# Copier bootstrap.txt
if [ -f "bootstrap.txt" ]; then
    cp bootstrap.txt "$INSTALL_DIR/bootstrap.txt"
    echo "   ✅ bootstrap.txt copié"
fi

# === SERVICE SYSTEMD ===
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
RestartSec=5
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
SERVICEEOF

# === FIREWALL ===
if command -v ufw &>/dev/null; then
    ufw allow 3030/tcp &>/dev/null || true
    ufw allow 4001/tcp &>/dev/null || true
    echo "   ✅ Ports ouverts (3030, 4001)"
fi

# === DÉMARRER ===
systemctl daemon-reload
systemctl enable zeta-relay
systemctl start zeta-relay

echo "   ✅ Service démarré"

sleep 2

# === RÉSULTAT ===
IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "════════════════════════════════════════════"
echo "✅ RELAIS ZETA INSTALLÉ ET DÉMARRÉ !"
echo "════════════════════════════════════════════"
echo ""
echo "🌍 Interface web : http://$IP:3030"
echo "🔗 P2P port      : $IP:4001"
echo ""
echo "📋 Commandes utiles :"
echo "   sudo systemctl status zeta-relay"
echo "   sudo journalctl -u zeta-relay -f"
echo ""
echo "🔄 Pour mettre à jour :"
echo "   cd ~/zeta-network && git pull"
echo "   cd rust-node && sudo ./install-relay.sh"
echo ""
