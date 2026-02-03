//! Zeta Network - Réseau social P2P décentralisé
//! 
//! Architecture : libp2p 0.51 + Gossipsub + mDNS + TCP + Yamux

use libp2p::{
    core::upgrade,
    gossipsub::{self, IdentTopic, MessageAuthenticity},
    mdns,
    noise, yamux,
    swarm::{SwarmBuilder, SwarmEvent},
    tcp::tokio::Transport as TokioTcpTransport,
    Multiaddr, PeerId, Transport,
};
use libp2p::swarm::NetworkBehaviour;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, RwLock};
use tracing::{error, info, warn};

mod web_server;

const TOPIC: &str = "zeta2-social";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Post {
    pub id: String,
    pub author: String,
    pub author_name: String,
    pub content: String,
    pub timestamp: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum NetworkMessage {
    Post(Post),
    Heartbeat { peer_id: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerInfo {
    pub peer_id: String,
    pub address: String,
    pub name: Option<String>,
    pub is_browser: bool,
}

/// Comportement réseau combiné
#[derive(NetworkBehaviour)]
#[behaviour(out_event = "ZetaEvent")]
struct ZetaBehaviour {
    gossipsub: gossipsub::Behaviour,
    mdns: mdns::tokio::Behaviour,
}

#[derive(Debug)]
enum ZetaEvent {
    Gossipsub(gossipsub::Event),
    Mdns(mdns::Event),
}

impl From<gossipsub::Event> for ZetaEvent {
    fn from(event: gossipsub::Event) -> Self {
        ZetaEvent::Gossipsub(event)
    }
}

impl From<mdns::Event> for ZetaEvent {
    fn from(event: mdns::Event) -> Self {
        ZetaEvent::Mdns(event)
    }
}

#[derive(Clone)]
pub struct NetworkState {
    pub peers: Arc<RwLock<HashMap<String, PeerInfo>>>,
    pub posts: Arc<RwLock<Vec<Post>>>,
    pub local_peer_id: PeerId,
    pub local_name: String,
    pub ws_broadcast: broadcast::Sender<String>,
}

impl NetworkState {
    fn new(local_peer_id: PeerId, local_name: String) -> Self {
        let (ws_broadcast, _) = broadcast::channel(100);
        Self {
            peers: Arc::new(RwLock::new(HashMap::new())),
            posts: Arc::new(RwLock::new(Vec::new())),
            local_peer_id,
            local_name,
            ws_broadcast,
        }
    }

    pub async fn add_peer(&self, peer_info: PeerInfo) {
        let peer_id = peer_info.peer_id.clone();
        self.peers.write().await.insert(peer_id.clone(), peer_info);
        let msg = serde_json::json!({"type": "peer_joined", "peer_id": peer_id});
        let _ = self.ws_broadcast.send(msg.to_string());
    }

    pub async fn remove_peer(&self, peer_id: &str) {
        self.peers.write().await.remove(peer_id);
        let msg = serde_json::json!({"type": "peer_left", "peer_id": peer_id});
        let _ = self.ws_broadcast.send(msg.to_string());
    }

    pub async fn add_post(&self, post: Post) {
        let mut posts = self.posts.write().await;
        if posts.iter().any(|p| p.id == post.id) {
            return;
        }
        posts.insert(0, post.clone());
        if posts.len() > 1000 {
            posts.truncate(1000);
        }
        let msg = serde_json::json!({"type": "new_post", "post": post});
        let _ = self.ws_broadcast.send(msg.to_string());
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_env_filter("info,libp2p=warn")
        .init();

    info!("🚀 Démarrage de Zeta Network");

    let args: Vec<String> = std::env::args().collect();
    let is_relay = args.iter().any(|a| a == "--relay" || a == "--server");
    
    let username = args.iter()
        .position(|x| x == "--name")
        .and_then(|i| args.get(i + 1))
        .cloned();
    
    let web_port: u16 = args.iter()
        .position(|x| x == "--web-port")
        .and_then(|i| args.get(i + 1))
        .and_then(|p| p.parse().ok())
        .unwrap_or(3030);

    info!("⚙️ Mode: {}", if is_relay { "RELAY" } else { "CLIENT" });

    let local_key = load_or_create_keypair("identity.key")?;
    let local_peer_id = PeerId::from(local_key.public());
    let local_name = username.unwrap_or_else(|| format!("Peer-{}", &local_peer_id.to_string()[..8]));

    info!("🔑 Peer ID: {}", local_peer_id);
    info!("👤 Nom: {}", local_name);

    // Transport TCP + Noise + Yamux
    let transport = TokioTcpTransport::new(Default::default())
        .upgrade(upgrade::Version::V1)
        .authenticate(noise::Config::new(&local_key).expect("Noise config"))
        .multiplex(yamux::Config::default())
        .boxed();

    // Gossipsub - configuration optimisée pour relais distants
    let gossipsub_config = gossipsub::ConfigBuilder::default()
        .heartbeat_interval(Duration::from_secs(5))  // Heartbeat plus fréquent
        .validation_mode(gossipsub::ValidationMode::Permissive)
        .mesh_n_low(2)           // Minimum 2 peers dans le mesh
        .mesh_n(3)               // Cible 3 peers
        .mesh_n_high(6)          // Maximum 6 peers
        .mesh_outbound_min(1)    // Minimum 1 connexion sortante
        .gossip_lazy(3)          // Gossip à 3 peers
        .history_length(5)       // Garder 5 heartbeats d'historique
        .history_gossip(3)       // Gossip les 3 derniers
        .duplicate_cache_time(Duration::from_secs(60))  // Cache de déduplication
        .build()
        .expect("Config Gossipsub valide");

    let mut gossipsub = gossipsub::Behaviour::new(
        MessageAuthenticity::Signed(local_key.clone()),
        gossipsub_config,
    ).expect("Gossipsub créé");

    let topic = IdentTopic::new(TOPIC);
    gossipsub.subscribe(&topic).unwrap();
    info!("📢 Abonné au topic: {}", TOPIC);

    // mDNS
    let mdns = mdns::tokio::Behaviour::new(mdns::Config::default(), local_peer_id)?;

    let behaviour = ZetaBehaviour { gossipsub, mdns };

    // Swarm
    let mut swarm = SwarmBuilder::with_tokio_executor(transport, behaviour, local_peer_id).build();

    // Écouter
    if is_relay {
        match swarm.listen_on("/ip4/0.0.0.0/tcp/4001".parse()?) {
            Ok(_) => info!("🖥️ Mode RELAY - Écoute sur 0.0.0.0:4001"),
            Err(e) => {
                error!("❌ Impossible d'écouter sur le port 4001: {}", e);
                error!("   Le port est peut-être déjà utilisé. Vérifiez avec: sudo lsof -i :4001");
                return Err(e.into());
            }
        }
    } else {
        swarm.listen_on("/ip4/0.0.0.0/tcp/0".parse()?)?;
        info!("💻 Mode CLIENT - Port aléatoire");
    }

    // Obtenir l'IP locale pour éviter de se connecter à soi-même
    let local_ip = get_local_ip();
    info!("📍 IP locale détectée: {}", local_ip.as_deref().unwrap_or("inconnue"));

    // Bootstrap peers - connexion sans Peer ID requis
    let bootstrap_addrs = load_bootstrap_addrs();
    for addr in &bootstrap_addrs {
        // Éviter de se connecter à soi-même
        let addr_str = addr.to_string();
        if let Some(ref lip) = local_ip {
            if addr_str.contains(lip) {
                info!("⏭️ Ignore bootstrap (c'est nous): {}", addr);
                continue;
            }
        }
        info!("🔗 Connexion au bootstrap: {}", addr);
        if let Err(e) = swarm.dial(addr.clone()) {
            warn!("⚠️ Échec connexion bootstrap: {}", e);
        }
    }

    let network_state = NetworkState::new(local_peer_id, local_name.clone());
    
    let (post_tx, mut post_rx) = mpsc::unbounded_channel::<Post>();
    let (ws_to_p2p_tx, mut ws_to_p2p_rx) = mpsc::unbounded_channel::<NetworkMessage>();

    // Serveur web
    let web_state = network_state.clone();
    let web_name = local_name.clone();
    tokio::spawn(async move {
        if let Err(e) = web_server::start_server(web_state, post_tx, ws_to_p2p_tx, web_name, is_relay, web_port).await {
            error!("❌ Erreur serveur web: {}", e);
        }
    });

    info!("🌐 Interface web: http://localhost:{}", web_port);
    info!("🎉 Zeta Network prêt!");
    info!("📋 Bootstrap configurés: {:?}", bootstrap_addrs.iter().map(|a| a.to_string()).collect::<Vec<_>>());

    // Intervalle de reconnexion (30s) pour maintenir le mesh actif
    let mut reconnect_interval = tokio::time::interval(Duration::from_secs(30));
    let bootstrap_clone = bootstrap_addrs.clone();
    let local_ip_clone = local_ip.clone();
    
    // Tracker les peers connectés
    let mut connected_peers: std::collections::HashSet<PeerId> = std::collections::HashSet::new();

    use futures::StreamExt;
    
    loop {
        tokio::select! {
            _ = reconnect_interval.tick() => {
                info!("📊 Status: {} peer(s) connecté(s)", connected_peers.len());
                
                // Toujours essayer de maintenir les connexions aux bootstrap
                for addr in &bootstrap_clone {
                    let addr_str = addr.to_string();
                    // Éviter de se connecter à soi-même
                    if let Some(ref lip) = local_ip_clone {
                        if addr_str.contains(lip) {
                            continue;
                        }
                    }
                    // Dial même si déjà connecté - libp2p gère les doublons
                    let _ = swarm.dial(addr.clone());
                }
            }

            Some(msg) = ws_to_p2p_rx.recv() => {
                if let Ok(json) = serde_json::to_vec(&msg) {
                    // Log le nombre de peers dans le mesh pour ce topic
                    let mesh_peers = swarm.behaviour().gossipsub.mesh_peers(&topic.hash()).count();
                    info!("📊 Mesh peers pour {}: {}", TOPIC, mesh_peers);
                    
                    // Publier sur Gossipsub
                    match swarm.behaviour_mut().gossipsub.publish(topic.clone(), json) {
                        Ok(_) => {
                            if let NetworkMessage::Post(ref p) = msg {
                                info!("📤 Post propagé sur Gossipsub ({} mesh peers): {}", mesh_peers, p.content);
                            }
                        }
                        Err(e) => {
                            warn!("⚠️ Gossipsub publish ({} mesh peers): {:?}", mesh_peers, e);
                        }
                    }
                    // Note: add_post déjà appelé dans web_server.rs, pas besoin ici
                }
            }

            Some(post) = post_rx.recv() => {
                let msg = NetworkMessage::Post(post.clone());
                if let Ok(json) = serde_json::to_vec(&msg) {
                    let mesh_peers = swarm.behaviour().gossipsub.mesh_peers(&topic.hash()).count();
                    match swarm.behaviour_mut().gossipsub.publish(topic.clone(), json) {
                        Ok(_) => info!("📤 Post publié via REST ({} mesh peers): {}", mesh_peers, post.content),
                        Err(e) => warn!("⚠️ Gossipsub publish ({} mesh peers): {:?}", mesh_peers, e),
                    }
                    // Toujours ajouter localement même si Gossipsub échoue
                    network_state.add_post(post).await;
                }
            }

            event = swarm.select_next_some() => {
                match event {
                    SwarmEvent::NewListenAddr { address, .. } => {
                        let full_addr = format!("{}/p2p/{}", address, local_peer_id);
                        info!("🎧 Écoute sur: {}", full_addr);
                        if is_relay {
                            info!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                            info!("📋 BOOTSTRAP ADDR: {}", full_addr);
                            info!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                        }
                    }

                    SwarmEvent::Behaviour(ZetaEvent::Gossipsub(gossipsub::Event::Message {
                        message, propagation_source, ..
                    })) => {
                        if let Ok(msg) = serde_json::from_slice::<NetworkMessage>(&message.data) {
                            if let NetworkMessage::Post(post) = msg {
                                info!("📨 Post reçu via Gossipsub de {}: {} - \"{}\"", 
                                      propagation_source, post.author_name, post.content);
                                network_state.add_post(post).await;
                            }
                        }
                    }
                    
                    SwarmEvent::Behaviour(ZetaEvent::Gossipsub(gossipsub::Event::Subscribed { peer_id, topic })) => {
                        info!("🔔 Peer {} s'est abonné au topic {}", peer_id, topic);
                    }
                    
                    SwarmEvent::Behaviour(ZetaEvent::Gossipsub(gossipsub::Event::Unsubscribed { peer_id, topic })) => {
                        info!("🔕 Peer {} s'est désabonné du topic {}", peer_id, topic);
                    }

                    SwarmEvent::Behaviour(ZetaEvent::Mdns(mdns::Event::Discovered(list))) => {
                        for (peer_id, addr) in list {
                            info!("🔍 Découvert via mDNS: {}", peer_id);
                            swarm.behaviour_mut().gossipsub.add_explicit_peer(&peer_id);
                            network_state.add_peer(PeerInfo {
                                peer_id: peer_id.to_string(),
                                address: addr.to_string(),
                                name: None,
                                is_browser: false,
                            }).await;
                        }
                    }

                    SwarmEvent::Behaviour(ZetaEvent::Mdns(mdns::Event::Expired(list))) => {
                        for (peer_id, _) in list {
                            info!("⏰ Expiré: {}", peer_id);
                            network_state.remove_peer(&peer_id.to_string()).await;
                        }
                    }

                    SwarmEvent::ConnectionEstablished { peer_id, endpoint, .. } => {
                        info!("✅ Connecté à {}", peer_id);
                        info!("   Endpoint: {:?}", endpoint);
                        connected_peers.insert(peer_id);
                        swarm.behaviour_mut().gossipsub.add_explicit_peer(&peer_id);
                        network_state.add_peer(PeerInfo {
                            peer_id: peer_id.to_string(),
                            address: format!("{:?}", endpoint),
                            name: None,
                            is_browser: false,
                        }).await;
                        info!("📊 Total peers connectés: {}", connected_peers.len());
                    }

                    SwarmEvent::ConnectionClosed { peer_id, cause, .. } => {
                        info!("❌ Déconnecté de {}", peer_id);
                        if let Some(err) = cause {
                            info!("   Cause: {}", err);
                        }
                        connected_peers.remove(&peer_id);
                        network_state.remove_peer(&peer_id.to_string()).await;
                        info!("📊 Total peers connectés: {}", connected_peers.len());
                    }
                    
                    SwarmEvent::OutgoingConnectionError { peer_id, error, .. } => {
                        if let Some(pid) = peer_id {
                            warn!("⚠️ Erreur connexion sortante vers {}: {}", pid, error);
                        } else {
                            warn!("⚠️ Erreur connexion sortante: {}", error);
                        }
                    }
                    
                    SwarmEvent::IncomingConnectionError { error, .. } => {
                        warn!("⚠️ Erreur connexion entrante: {}", error);
                    }

                    _ => {}
                }
            }
        }
    }
}

fn load_or_create_keypair(path: &str) -> Result<libp2p::identity::Keypair, Box<dyn Error>> {
    use libp2p::identity::Keypair;
    
    if Path::new(path).exists() {
        info!("🔐 Chargement de la clé existante...");
        let bytes = fs::read(path)?;
        Ok(Keypair::from_protobuf_encoding(&bytes)?)
    } else {
        info!("🔑 Génération d'une nouvelle clé...");
        let key = Keypair::generate_ed25519();
        fs::write(path, key.to_protobuf_encoding()?)?;
        info!("💾 Clé sauvegardée dans {}", path);
        Ok(key)
    }
}

fn load_bootstrap_addrs() -> Vec<Multiaddr> {
    let path = "bootstrap.txt";
    let mut addrs = Vec::new();
    
    if !Path::new(path).exists() {
        let example = "# Bootstrap peers Zeta Network\n# Format: /ip4/IP/tcp/PORT (Peer ID not required)\n# Example: /ip4/65.75.201.11/tcp/4001\n";
        let _ = fs::write(path, example);
        return addrs;
    }

    if let Ok(file) = fs::File::open(path) {
        for line in BufReader::new(file).lines().flatten() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Ok(addr) = line.parse::<Multiaddr>() {
                info!("📋 Bootstrap configuré: {}", addr);
                addrs.push(addr);
            } else {
                warn!("⚠️ Adresse invalide dans bootstrap.txt: {}", line);
            }
        }
    }

    addrs
}

/// Obtenir l'IP publique du serveur
fn get_local_ip() -> Option<String> {
    // Essayer de récupérer l'IP publique
    if let Ok(output) = std::process::Command::new("curl")
        .args(["-s", "--max-time", "3", "ifconfig.me"])
        .output()
    {
        if output.status.success() {
            if let Ok(ip) = String::from_utf8(output.stdout) {
                let ip = ip.trim().to_string();
                if !ip.is_empty() {
                    return Some(ip);
                }
            }
        }
    }
    
    // Fallback: utiliser hostname
    if let Ok(output) = std::process::Command::new("hostname")
        .arg("-I")
        .output()
    {
        if output.status.success() {
            if let Ok(ips) = String::from_utf8(output.stdout) {
                if let Some(ip) = ips.split_whitespace().next() {
                    return Some(ip.to_string());
                }
            }
        }
    }
    
    None
}