#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║      🔧 Installation Zeta Network Relay (CORRIGÉ)         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

# 1. Dépendances
echo -e "${BLUE}📦 Installation dépendances...${NC}"
apt-get update > /dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install -y curl git build-essential libssl-dev pkg-config > /dev/null 2>&1 || true

# 2. Rust
if ! command -v cargo &> /dev/null; then
    echo -e "${BLUE}⚙️  Installation Rust...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal > /dev/null 2>&1
    source "/root/.cargo/env" 2>/dev/null || source "$HOME/.cargo/env"
fi

# 3. Installation PROPRE (supprimer tout ancien résidu)
INSTALL_DIR="/opt/zeta-relay"
echo -e "${BLUE}🧹 Nettoyage ancienne installation...${NC}"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 4. Cloner DANS un sous-dossier temporaire pour éviter la pollution
echo -e "${BLUE}📥 Clonage dépôt GitHub (cTHE0)...${NC}"
cd "$INSTALL_DIR"
git clone https://github.com/cTHE0/zeta-network.git zeta-src > /dev/null 2>&1 || {
    echo -e "${YELLOW}⚠️  Tentative avec proxy...${NC}"
    git clone https://ghproxy.com/https://github.com/cTHE0/zeta-network.git zeta-src > /dev/null 2>&1 || {
        echo -e "${RED}❌ Échec clonage GitHub${NC}"
        exit 1
    }
}

# 5. COPIER SEULEMENT le dossier rust-node (critique !)
echo -e "${BLUE}📋 Extraction dossier rust-node...${NC}"
cp -r zeta-src/rust-node .
rm -rf zeta-src  # Nettoyer le dépôt complet

# 6. Vérification CRITIQUE du Cargo.toml
cd "$INSTALL_DIR/rust-node"
echo -e "${BLUE}🔍 Vérification Cargo.toml...${NC}"

if [ ! -f Cargo.toml ]; then
    echo -e "${RED}❌ ERREUR: Cargo.toml introuvable dans $(pwd)${NC}"
    ls -la
    exit 1
fi

# Détecter BOM UTF-8 ou caractères invalides
if head -c 3 Cargo.toml | od -An -tx1 | grep -q "ef bb bf"; then
    echo -e "${YELLOW}⚠️  BOM UTF-8 détecté - nettoyage...${NC}"
    tail -c +4 Cargo.toml > Cargo.toml.tmp && mv Cargo.toml.tmp Cargo.toml
fi

# Vérifier format TOML valide
if ! grep -q "^\[package\]" Cargo.toml 2>/dev/null; then
    echo -e "${RED}❌ ERREUR: Cargo.toml invalide${NC}"
    echo "Premières lignes:"
    head -10 Cargo.toml
    echo ""
    echo "Hex dump (premiers 64 octets):"
    head -c 64 Cargo.toml | od -An -tx1
    exit 1
fi

echo -e "${GREEN}✅ Cargo.toml valide${NC}"

# 7. Compilation depuis le bon dossier
echo -e "${BLUE}🔨 Compilation (5-10 min)...${NC}"
cargo build --release --quiet || {
    echo -e "${RED}❌ Échec compilation${NC}"
    echo "Erreur détaillée:"
    cargo build --release 2>&1 | tail -20
    exit 1
}

# 8. Service systemd avec WorkingDirectory EXACT
echo -e "${BLUE}⚙️  Configuration systemd...${NC}"
cat > /etc/systemd/system/zeta-relay.service <<EOF
[Unit]
Description=Zeta Network Relay
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/zeta-relay/rust-node
ExecStart=/opt/zeta-relay/rust-node/target/release/zeta-network --relay --name "Relay-\$(hostname)" --web-port 3030
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zeta-relay 2>/dev/null
systemctl start zeta-relay

# 9. Résultat
sleep 15
PEER_ID=$(curl -s http://localhost:3030/api/network 2>/dev/null | grep -oP '"local_peer_id":"\K[^"]+' | head -1 || echo "en_attente")
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' | head -1)

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ RELAIS INSTALLÉ AVEC SUCCÈS !              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}🌐 Adresse bootstrap :${NC}"
echo -e "${YELLOW}/ip4/${PUBLIC_IP}/tcp/4001/p2p/${PEER_ID}${NC}"
echo ""
echo -e "${BLUE}🌐 Interface web : http://${PUBLIC_IP}:3030${NC}"
echo ""
echo -e "${GREEN}🎉 Relais opérationnel !${NC}"