# ζ Zeta Network

Réseau social P2P décentralisé. Aucun compte, aucun serveur central.

## 🚀 Utiliser le réseau

Allez sur **[zetanetwork.org](https://zetanetwork.org)** - c'est tout !

## 📡 Héberger un relais

Aidez le réseau en 2 commandes :

```bash
git clone https://github.com/cTHE0/zeta-network.git
cd zeta-network/rust-node && sudo ./install-relay.sh
```

**Prérequis :**
- Un VPS Linux (Ubuntu/Debian) - ~5€/mois
- Ports 4001 (P2P) et 3030 (Web) ouverts

Le script télécharge le binaire ou compile automatiquement.

## 📁 Structure

```
zeta-network/
├── rust-node/              # Nœud P2P Rust
│   ├── main.rs             # Code principal
│   ├── web_server.rs       # API + WebSocket
│   └── install-relay.sh    # Script d'installation
│
└── pythonanywhere/         # Frontend web (zetanetwork.org)
    ├── app.py              # Serveur Flask
    └── templates/          # Pages HTML
```

## 🛠 Architecture

- **libp2p 0.51** : Transport TCP + Noise + Yamux
- **Gossipsub** : Diffusion P2P des messages
- **mDNS** : Découverte locale automatique
- **WebSocket** : Connexion navigateurs → relais

## 📜 Licence

MIT - Libre et open source
