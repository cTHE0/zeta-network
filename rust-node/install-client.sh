#!/bin/bash
# Installation du client Zeta Network - 1 commande
# Usage: curl -L https://zetanetwork.org/install-client.sh | bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           🚀 Installation Zeta Network Client             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

# Détection de l'architecture
ARCH=$(uname -m)
OS=$(uname -s)

echo -e "${GREEN}✓ Système: $OS $ARCH${NC}"

# URL des binaires pré-compilés
BASE_URL="https://github.com/CTHE0/zeta-network/releases/latest/download"

case "$OS" in
    Linux)
        case "$ARCH" in
            x86_64) BIN_NAME="zeta-network-linux-x86_64" ;;
            aarch64) BIN_NAME="zeta-network-linux-aarch64" ;;
            armv7l) BIN_NAME="zeta-network-linux-armv7" ;;
            *) echo -e "${RED}❌ Architecture non supportée: $ARCH${NC}"; exit 1 ;;
        esac
        ;;
    Darwin)
        case "$ARCH" in
            x86_64) BIN_NAME="zeta-network-macos-x86_64" ;;
            arm64) BIN_NAME="zeta-network-macos-arm64" ;;
            *) echo -e "${RED}❌ Architecture non supportée: $ARCH${NC}"; exit 1 ;;
        esac
        ;;
    MINGW*|MSYS*|CYGWIN*)
        BIN_NAME="zeta-network-windows-x86_64.exe"
        ;;
    *)
        echo -e "${RED}❌ OS non supporté: $OS${NC}"
        exit 1
        ;;
esac

INSTALL_DIR="${HOME}/.zeta-client"
mkdir -p "$INSTALL_DIR"

echo -e "${BLUE}📥 Téléchargement du binaire...${NC}"
echo "URL: $BASE_URL/$BIN_NAME"

cd "$INSTALL_DIR"

# Essayer GitHub Releases, sinon build local
if curl -L -o zeta-network "$BASE_URL/$BIN_NAME" 2>/dev/null; then
    echo -e "${GREEN}✓ Binaire téléchargé${NC}"
    chmod +x zeta-network
else
    echo -e "${YELLOW}⚠️  Binaire non trouvé. Compilation locale...${NC}"
    
    # Installation de Rust si nécessaire
    if ! command -v cargo &> /dev/null; then
        echo -e "${BLUE}⚙️  Installation de Rust...${NC}"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
    
    # Cloner et compiler
    if [ ! -f main.rs ]; then
        curl -L -o main.rs https://raw.githubusercontent.com/CTHE0/zeta-network/main/rust-node/main.rs
        curl -L -o web_server.rs https://raw.githubusercontent.com/CTHE0/zeta-network/main/rust-node/web_server.rs
        curl -L -o Cargo.toml https://raw.githubusercontent.com/CTHE0/zeta-network/main/rust-node/Cargo.toml
    fi
    
    echo -e "${BLUE}🔨 Compilation...${NC}"
    cargo build --release
    cp target/release/zeta-network .
fi

# Créer bootstrap.txt avec relais publics
if [ ! -f bootstrap.txt ]; then
    cat > bootstrap.txt <<EOF
# Relais publics Zeta Network
# Ajoutez vos propres relais ici

# /ip4/1.2.3.4/tcp/4001/p2p/12D3KooW...
EOF
    
    echo -e "${YELLOW}⚠️  Modifiez bootstrap.txt avec l'adresse de votre relais${NC}"
fi

# Créer un script de lancement pratique
cat > start.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"

# Nom par défaut
NAME="${ZETA_NAME:-$(whoami)}"

# Relais depuis bootstrap.txt
RELAY_ADDR=$(grep -v '^#' bootstrap.txt | grep '/ip4/' | head -1)

if [ -z "$RELAY_ADDR" ]; then
    echo "❌ Aucun relais configuré dans bootstrap.txt"
    echo "Ajoutez une ligne: /ip4/IP/tcp/4001/p2p/PEER_ID"
    exit 1
fi

echo "🚀 Démarrage du client Zeta Network"
echo "👤 Nom: $NAME"
echo "🔗 Relais: $RELAY_ADDR"
echo ""

exec ./zeta-network --name "$NAME" --relay-addr "$RELAY_ADDR" --web-port 3030
EOF

chmod +x start.sh

# Créer un alias
echo 'export PATH="$HOME/.zeta-client:$PATH"' >> ~/.bashrc
echo 'alias zeta="~/.zeta-client/start.sh"' >> ~/.bashrc

if [ -f ~/.zshrc ]; then
    echo 'export PATH="$HOME/.zeta-client:$PATH"' >> ~/.zshrc
    echo 'alias zeta="~/.zeta-client/start.sh"' >> ~/.zshrc
fi

echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           ✅ CLIENT INSTALLÉ AVEC SUCCÈS !                 ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}🚀 Pour démarrer le client:${NC}"
echo "   ~/.zeta-client/start.sh"
echo "   ou"
echo "   zeta"
echo ""
echo -e "${BLUE}🌐 Interface web:${NC}"
echo "   http://localhost:3030"
echo ""
echo -e "${BLUE}📝 Configuration:${NC}"
echo "   Éditez ~/.zeta-client/bootstrap.txt pour ajouter des relais"
echo "   Exportez ZETA_NAME pour changer votre nom: export ZETA_NAME=Alice"
echo ""
echo -e "${YELLOW}💡 Prochaines étapes:${NC}"
echo "   1. Éditez bootstrap.txt avec l'adresse de votre relais"
echo "   2. Lancez: zeta"
echo "   3. Ouvrez http://localhost:3030 dans votre navigateur"
echo ""
echo -e "${GREEN}🎉 Installation terminée !${NC}"