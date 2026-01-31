#!/bin/bash
# Installation Zeta Network Relay - Version finale avec casse GitHub corrigée
# Usage: curl -fsSL https://zetanetwork.org/static/install-relay.sh | sudo bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           🚀 Installation Zeta Network Relay              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Nécessite sudo${NC}"
    exit 1
fi

# Dépendances
apt-get update > /dev/null 2>&1 || true
apt-get install -y curl wget git build-essential libssl-dev pkg-config > /dev/null 2>&1 || true

# Rust
if ! command -v cargo &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal > /dev/null 2>&1
    source "/root/.cargo/env"
fi

# Installation propre
INSTALL_DIR="/opt/zeta-relay"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Méthode 1 : git clone avec casse CORRECTE (cTHE0)
if git clone https://github.com/cTHE0/zeta-network.git . 2>/dev/null; then
    echo -e "${GREEN}✓ Dépôt cloné depuis github.com/cTHE0/zeta-network${NC}"
    cd rust-node || exit 1
    
# Méthode 2 : fallback fichier par fichier (avec casse CORRECTE)
else
    echo -e "${YELLOW}⚠️  Git indisponible - téléchargement direct${NC}"
    
    curl -fsSL "https://raw.githubusercontent.com/cTHE0/zeta-network/main/rust-node/Cargo.toml" -o Cargo.toml
    curl -fsSL "https://raw.githubusercontent.com/cTHE0/zeta-network/main/rust-node/main.rs" -o main.rs
    curl -fsSL "https://raw.githubusercontent.com/cTHE0/zeta-network/main/rust-node/web_server.rs" -o web_server.rs
    curl -fsSL "https://raw.githubusercontent.com/cTHE0/zeta-network/main/rust-node/bootstrap.txt" -o bootstrap.txt 2>/dev/null || echo "" > bootstrap.txt
    
    # Vérification critique
    if [ ! -s Cargo.toml ] || ! grep -q "package" Cargo.toml; then
        echo -e "${RED}❌ Échec téléchargement Cargo.toml${NC}"
        echo "Contenu reçu:"
        head -20 Cargo.toml || echo "(vide)"
        exit 1
    fi
    echo -e "${GREEN}✓ Fichiers téléchargés avec succès${NC}"
fi

# Build
echo -e "${BLUE}🔨 Compilation...${NC}"
cargo build --release --quiet || {
    echo -e "${RED}❌ Échec compilation${NC}"
    exit 1
}

# Service
cat > /etc/systemd/system/zeta-relay.service <<EOF
[Unit]
Description=Zeta Network Relay
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/rust-node
ExecStart=$INSTALL_DIR/rust-node/target/release/zeta-network --relay --name "Relay-\$(hostname)" --web-port 3030
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zeta-relay
systemctl start zeta-relay

# Résultat
sleep 10
PEER_ID=$(curl -s http://localhost:3030/api/network 2>/dev/null | grep -oP '"local_peer_id":"\K[^"]+' | head -1 || echo "en_attente")
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "IP_INCONNUE")

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ RELAIS INSTALLÉ AVEC SUCCÈS !              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}🌐 Bootstrap address:${NC}"
echo -e "${YELLOW}/ip4/${PUBLIC_IP}/tcp/4001/p2p/${PEER_ID}${NC}"
echo ""
echo -e "${BLUE}🌐 Web interface: http://${PUBLIC_IP}:3030${NC}"
echo ""
echo -e "${GREEN}🎉 Relais opérationnel !${NC}"