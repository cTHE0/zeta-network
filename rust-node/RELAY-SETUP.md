# Configuration des Relais Zeta Network

## Installation d'un nouveau relais

Sur votre VPS :

```bash
git clone https://github.com/cTHE0/zeta-network.git
cd zeta-network/rust-node
sudo ./install-relay.sh
```

Le relais sera automatiquement :
- Installé dans `/usr/local/bin/zeta-relay`
- Configuré comme service systemd `zeta-relay.service`
- Démarré et activé au boot
- Accessible sur `http://VOTRE_IP:3030`

## Connexion automatique entre relais

Les relais se connectent automatiquement entre eux grâce au fichier `bootstrap.txt` qui contient les adresses de tous les relais connus.

### Ajouter un nouveau relais au réseau

1. **Mettre à jour `bootstrap.txt`** localement :
   ```bash
   # Ajoutez cette ligne dans rust-node/bootstrap.txt
   /ip4/NOUVELLE_IP/tcp/4001
   ```

2. **Commit et push** :
   ```bash
   git add rust-node/bootstrap.txt
   git commit -m "Add relay: NOUVELLE_IP"
   git push
   ```

3. **Mettre à jour TOUS les relais** :
   ```bash
   # Sur chaque VPS existant
   cd ~/zeta-network
   git pull
   sudo systemctl restart zeta-relay
   ```

4. **Vérifier la connexion** :
   ```bash
   sudo journalctl -u zeta-relay -f
   # Vous devriez voir : "✅ Connecté: 12D3KooW..."
   ```

## Comment ça fonctionne

- Chaque relais lit `bootstrap.txt` au démarrage
- Il tente de se connecter à toutes les adresses listées
- Une fois connecté, il ajoute automatiquement le peer à Gossipsub
- Les messages sont propagés entre tous les relais via Gossipsub
- Reconnexion automatique toutes les 30 secondes en cas de déconnexion

## Architecture du réseau

```
┌──────────────┐         ┌──────────────┐
│   EU 1       │◄───────►│   EU 2       │
│ 65.75.201.11 │  P2P    │ 65.75.200.180│
└──────┬───────┘         └──────┬───────┘
       │                        │
       │    Gossipsub Topic     │
       │    "zeta2-social"      │
       │                        │
    ┌──▼──┐                  ┌──▼──┐
    │User1│                  │User2│
    └─────┘                  └─────┘
```

## Commandes utiles

```bash
# Voir les logs en temps réel
sudo journalctl -u zeta-relay -f

# Redémarrer le relais
sudo systemctl restart zeta-relay

# Voir le Peer ID du relais
sudo journalctl -u zeta-relay | grep "Peer ID"

# Voir les connexions actives
sudo journalctl -u zeta-relay | grep "Connecté"
```

## Relais actuels

| Nom  | IP             | WebSocket             | Web UI                  |
|------|----------------|-----------------------|-------------------------|
| EU 1 | 65.75.201.11   | ws://65.75.201.11:3030/ws | http://65.75.201.11:3030 |
| EU 2 | 65.75.200.180  | ws://65.75.200.180:3030/ws | http://65.75.200.180:3030 |
