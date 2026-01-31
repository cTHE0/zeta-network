#!/bin/bash
# Installation du relais Zeta Network - 1 commande
# Usage: curl -L https://zetanetwork.org/install-relay.sh | sudo bash

set -e

# Couleurs
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
    echo -e "${YELLOW}⚠️  Sudo requis. Veuillez entrer votre mot de passe...${NC}"
fi

# Détection de l'OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
elif [ "$(uname)" == "Darwin" ]; then
    OS="macOS"
else
    OS="Linux"
fi

echo -e "${GREEN}✓ OS détecté: $OS${NC}"

# Installation des dépendances
echo -e "${BLUE}📦 Installation des dépendances...${NC}"

if [[ "$OS" == *"Ubuntu"* || "$OS" == *"Debian"* ]]; then
    apt-get update > /dev/null 2>&1
    apt-get install -y curl wget git build-essential > /dev/null 2>&1
elif [[ "$OS" == *"CentOS"* || "$OS" == *"Fedora"* ]]; then
    yum install -y curl wget git gcc make > /dev/null 2>&1
elif [[ "$OS" == *"macOS"* ]]; then
    if ! command -v brew &> /dev/null; then
        echo -e "${YELLOW}⚠️  Homebrew non trouvé. Installation...${NC}"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install curl wget git > /dev/null 2>&1
fi

# Installation de Rust
if ! command -v cargo &> /dev/null; then
    echo -e "${BLUE}⚙️  Installation de Rust...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
else
    echo -e "${GREEN}✓ Rust déjà installé${NC}"
fi

# Créer le répertoire
INSTALL_DIR="${HOME}/zeta-relay"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Télécharger le code
echo -e "${BLUE}📥 Téléchargement du code source...${NC}"

if [ ! -f main.rs ]; then
    curl -L -o main.rs https://raw.githubusercontent.com/CTHE0/zeta-network/main/rust-node/main.rs
    curl -L -o web_server.rs https://raw.githubusercontent.com/CTHE0/zeta-network/main/rust-node/web_server.rs
    curl -L -o Cargo.toml https://raw.githubusercontent.com/CTHE0/zeta-network/main/rust-node/Cargo.toml
fi

# Créer bootstrap.txt si absent
if [ ! -f bootstrap.txt ]; then
    cat > bootstrap.txt <<EOF
# Bootstrap peers pour Zeta Network
# Ajoutez vos propres relais ici
EOF
fi

# Build en release
echo -e "${BLUE}🔨 Compilation en mode release...${NC}"
cargo build --release

# Créer le service systemd (Linux)
if [[ "$OS" != *"macOS"* ]]; then
    echo -e "${BLUE}⚙️  Configuration du service systemd...${NC}"
    
    cat > /tmp/zeta-relay.service <<EOF
[Unit]
Description=Zeta Network Relay
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/target/release/zeta-network --relay --name "Relay-$(hostname)" --web-port 3030
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    cp /tmp/zeta-relay.service /etc/systemd/system/zeta-relay.service
    systemctl daemon-reload
    systemctl enable zeta-relay
    systemctl start zeta-relay
    
    echo -e "${GREEN}✓ Service systemd configuré et démarré${NC}"
fi

# Ouvrir le port 4001 (Linux)
if command -v ufw &> /dev/null; then
    echo -e "${BLUE}🔓 Ouverture du port 4001...${NC}"
    ufw allow 4001/tcp > /dev/null 2>&1
fi

# Afficher l'adresse bootstrap
sleep 3

if [[ "$OS" == *"macOS"* ]]; then
    echo -e "${YELLOW}⚠️  macOS détecté. Démarrage manuel requis:${NC}"
    echo "   cd $INSTALL_DIR"
    echo "   ./target/release/zeta-network --relay --name \"Relay-$(hostname)\" --web-port 3030"
    echo ""
    echo -e "${GREEN}✅ Installation terminée !${NC}"
    exit 0
fi

# Récupérer le PeerID
echo -e "${BLUE}🔍 Récupération de l'adresse bootstrap...${NC}"
sleep 5

PEER_ID=$(curl -s http://localhost:3030/api/network 2>/dev/null | grep -oP '"local_peer_id":\s*"\K[^"]+' || echo "En attente...")

PUBLIC_IP=$(curl -s ifconfig.me || echo "IP non détectée")

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ RELAIS INSTALLÉ AVEC SUCCÈS !              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}🌐 Adresse bootstrap à partager:${NC}"
echo -e "${YELLOW}/ip4/${PUBLIC_IP}/tcp/4001/p2p/${PEER_ID}${NC}"
echo ""
echo -e "${BLUE}📊 Statut du service:${NC}"
systemctl status zeta-relay --no-pager
echo ""
echo -e "${BLUE}📝 Pour gérer le service:${NC}"
echo "   sudo systemctl start zeta-relay"
echo "   sudo systemctl stop zeta-relay"
echo "   sudo systemctl restart zeta-relay"
echo "   sudo systemctl status zeta-relay"
echo ""
echo -e "${BLUE}🌐 Interface web:${NC}"
echo -e "   http://localhost:3030"
echo -e "   http://${PUBLIC_IP}:3030"
echo ""
echo -e "${GREEN}🎉 Votre relais Zeta Network est opérationnel !${NC}"
echo -e "${YELLOW}💡 Partagez votre adresse bootstrap avec les autres utilisateurs${NC}"