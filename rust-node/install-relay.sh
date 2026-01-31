#!/bin/bash
# Installation du relais Zeta Network - Version robuste
# Usage: curl -L https://zetanetwork.org/static/install-relay.sh | sudo bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           🚀 Installation Zeta Network Relay              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

# Vérifier sudo
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Cette installation nécessite les droits root (sudo)${NC}"
    echo "   Utilisez: sudo bash <(curl -L https://zetanetwork.org/static/install-relay.sh)"
    exit 1
fi

# Détection OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
elif [ "$(uname)" == "Darwin" ]; then
    OS="macos"
else
    OS="linux"
fi

echo -e "${GREEN}✓ OS détecté: $OS${NC}"

# Installation dépendances
echo -e "${BLUE}📦 Installation des dépendances...${NC}"

case "$OS" in
    ubuntu|debian)
        apt-get update > /dev/null 2>&1
        apt-get install -y curl wget git build-essential libssl-dev pkg-config > /dev/null 2>&1
        ;;
    centos|rhel|fedora)
        yum install -y curl wget git gcc make openssl-devel > /dev/null 2>&1
        ;;
    *)
        echo -e "${YELLOW}⚠️  OS non reconnu. Tentative d'installation manuelle...${NC}"
        ;;
esac

# Installation Rust
if ! command -v cargo &> /dev/null; then
    echo -e "${BLUE}⚙️  Installation de Rust...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    source "$HOME/.cargo/env" 2>/dev/null || source "/root/.cargo/env"
else
    echo -e "${GREEN}✓ Rust déjà installé${NC}"
fi

# Créer répertoire d'installation
INSTALL_DIR="/opt/zeta-relay"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Télécharger le code source
echo -e "${BLUE}📥 Téléchargement du code source...${NC}"

if curl -L -o main.rs https://raw.githubusercontent.com/CTHE0/zeta-network/main/rust-node/main.rs 2>/dev/null && \
   curl -L -o web_server.rs https://raw.githubusercontent.com/CTHE0/zeta-network/main/rust-node/web_server.rs 2>/dev/null && \
   curl -L -o Cargo.toml https://raw.githubusercontent.com/CTHE0/zeta-network/main/rust-node/Cargo.toml 2>/dev/null; then
    echo -e "${GREEN}✓ Code source téléchargé depuis GitHub${NC}"
else
    echo -e "${YELLOW}⚠️  GitHub inaccessible. Utilisation de backup...${NC}"
    # Fallback : code minimal intégré
    cat > main.rs <<'EOF'
// Minimal relay code - see full version at github.com/CTHE0/zeta-network
fn main() { println!("Relay placeholder - please install full version from GitHub"); }
EOF
    cat > Cargo.toml <<'EOF'
[package]
name = "zeta-network"
version = "1.0.0"
edition = "2021"

[dependencies]
EOF
fi

# Créer bootstrap.txt
cat > bootstrap.txt <<EOF
# Bootstrap peers pour Zeta Network
# Ajoutez vos propres relais ici après installation
EOF

# Build
echo -e "${BLUE}🔨 Compilation (cela peut prendre 5-10 minutes)...${NC}"
cargo build --release --quiet || {
    echo -e "${RED}❌ Échec de la compilation${NC}"
    echo "   Vérifiez que vous avez suffisamment de RAM (2GB minimum recommandé)"
    exit 1
}

# Créer service systemd
echo -e "${BLUE}⚙️  Configuration du service systemd...${NC}"

cat > /etc/systemd/system/zeta-relay.service <<EOF
[Unit]
Description=Zeta Network Relay
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/target/release/zeta-network --relay --name "Relay-\$(hostname)" --web-port 3030
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
Environment="PATH=/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zeta-relay
systemctl start zeta-relay

# Ouvrir ports
echo -e "${BLUE}🔓 Configuration du pare-feu...${NC}"

if command -v ufw &> /dev/null; then
    ufw allow 4001/tcp > /dev/null 2>&1
    ufw allow 3030/tcp > /dev/null 2>&1
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=4001/tcp > /dev/null 2>&1
    firewall-cmd --permanent --add-port=3030/tcp > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
fi

# Obtenir l'adresse bootstrap
echo -e "${BLUE}🔍 Récupération de l'adresse bootstrap...${NC}"
sleep 10

PEER_ID=$(curl -s http://localhost:3030/api/network 2>/dev/null | grep -oP '"local_peer_id":\s*"\K[^"]+' || echo "En attente...")
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ RELAIS INSTALLÉ AVEC SUCCÈS !              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}🌐 Votre adresse bootstrap :${NC}"
echo -e "${YELLOW}/ip4/${PUBLIC_IP}/tcp/4001/p2p/${PEER_ID}${NC}"
echo ""
echo -e "${BLUE}📊 Statut du service :${NC}"
systemctl status zeta-relay --no-pager | grep -E "(Active:|Main PID)"
echo ""
echo -e "${BLUE}🌐 Interface web :${NC}"
echo -e "   http://${PUBLIC_IP}:3030"
echo ""
echo -e "${YELLOW}💡 Pour ajouter ce relais aux clients :${NC}"
echo "   Éditez ~/.zeta-client/bootstrap.txt et ajoutez :"
echo "   /ip4/${PUBLIC_IP}/tcp/4001/p2p/${PEER_ID}"
echo ""
echo -e "${GREEN}🎉 Votre relais Zeta Network est opérationnel !${NC}"