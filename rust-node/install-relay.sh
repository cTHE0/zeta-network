#!/bin/bash
# install-relay.sh - Version simplifiée pour users lambda
# Usage: git clone https://github.com/cTHE0/zeta-network.git && cd zeta-network/rust-node && sudo bash install-relay.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      🚀 Installation Zeta Network Relay (Simple)          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

# Vérifier sudo
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Nécessite sudo. Relancez avec : sudo bash install-relay.sh${NC}"
    exit 1
fi

# Vérifier qu'on est dans le bon dossier
if [ ! -f "Cargo.toml" ] || [ ! -f "main.rs" ]; then
    echo -e "${RED}❌ ERREUR: Ce script doit être exécuté depuis le dossier rust-node/${NC}"
    echo "   Structure attendue:"
    echo "   zeta-network/"
    echo "   └── rust-node/"
    echo "       ├── Cargo.toml  ← doit exister"
    echo "       ├── main.rs     ← doit exister"
    echo "       └── install-relay.sh"
    exit 1
fi

# 1. Dépendances
echo -e "${BLUE}📦 Installation dépendances...${NC}"
apt-get update > /dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install -y curl build-essential libssl-dev pkg-config > /dev/null 2>&1 || true

# 2. Rust (si absent)
if ! command -v cargo &> /dev/null; then
    echo -e "${BLUE}⚙️  Installation Rust (1-2 min)...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal > /dev/null 2>&1
    source "/root/.cargo/env" 2>/dev/null || source "$HOME/.cargo/env"
fi

# 3. Compilation
echo -e "${BLUE}🔨 Compilation (5-10 min)...${NC}"
cargo build --release --quiet || {
    echo -e "${RED}❌ Échec compilation${NC}"
    exit 1
}

# 4. Service systemd (pour persistance au reboot)
echo -e "${BLUE}⚙️  Configuration systemd...${NC}"
INSTALL_PATH="$(pwd)"

cat > /etc/systemd/system/zeta-relay.service <<EOF
[Unit]
Description=Zeta Network Relay
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_PATH
ExecStart=$INSTALL_PATH/target/release/zeta-network --relay --name "Relay-\$(hostname)" --web-port 3030
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zeta-relay > /dev/null 2>&1
systemctl start zeta-relay

# 5. Résultat
sleep 10
PEER_ID=$(curl -s http://localhost:3030/api/network 2>/dev/null | grep -oP '"local_peer_id":"\K[^"]+' | head -1 || echo "en_attente")
PUBLIC_IP=$(curl -s ifconfig.me 2>&1 || hostname -I | awk '{print $1}' | head -1)

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ RELAIS OPÉRATIONNEL !                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}🌐 Votre adresse bootstrap :${NC}"
echo -e "${YELLOW}/ip4/${PUBLIC_IP}/tcp/4001/p2p/${PEER_ID}${NC}"
echo ""
echo -e "${BLUE}🌐 Interface web : http://${PUBLIC_IP}:3030${NC}"
echo ""
echo -e "${BLUE}📝 Pour gérer le service :${NC}"
echo "   sudo systemctl start zeta-relay"
echo "   sudo systemctl stop zeta-relay"
echo "   sudo systemctl restart zeta-relay"
echo "   sudo systemctl status zeta-relay"
echo ""
echo -e "${GREEN}🎉 Partagez votre adresse bootstrap avec d'autres utilisateurs !${NC}"