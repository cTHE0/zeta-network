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

    // Gossipsub
    let gossipsub_config = gossipsub::ConfigBuilder::default()
        .heartbeat_interval(Duration::from_secs(10))
        .validation_mode(gossipsub::ValidationMode::Permissive)
        .build()
        .expect("Config Gossipsub valide");

    let mut gossipsub = gossipsub::Behaviour::new(
        MessageAuthenticity::Signed(local_key.clone()),
        gossipsub_config,
    ).expect("Gossipsub créé");

    let topic = IdentTopic::new(TOPIC);
    gossipsub.subscribe(&topic).unwrap();

    // mDNS
    let mdns = mdns::tokio::Behaviour::new(mdns::Config::default(), local_peer_id)?;

    let behaviour = ZetaBehaviour { gossipsub, mdns };

    // Swarm
    let mut swarm = SwarmBuilder::with_tokio_executor(transport, behaviour, local_peer_id).build();

    // Écouter
    if is_relay {
        swarm.listen_on("/ip4/0.0.0.0/tcp/4001".parse()?)?;
        info!("🖥️ Mode RELAY - Écoute sur 0.0.0.0:4001");
    } else {
        swarm.listen_on("/ip4/0.0.0.0/tcp/0".parse()?)?;
        info!("💻 Mode CLIENT - Port aléatoire");
    }

    // Bootstrap peers
    let bootstrap_peers = load_bootstrap_peers();
    for (peer_id, addr) in &bootstrap_peers {
        info!("🔗 Connexion au bootstrap: {}", addr);
        if let Err(e) = swarm.dial(addr.clone()) {
            warn!("⚠️ Échec connexion bootstrap: {}", e);
        }
        swarm.behaviour_mut().gossipsub.add_explicit_peer(peer_id);
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

    let mut reconnect_interval = tokio::time::interval(Duration::from_secs(30));
    let bootstrap_clone = bootstrap_peers.clone();

    use futures::StreamExt;
    
    loop {
        tokio::select! {
            _ = reconnect_interval.tick() => {
                for (peer_id, addr) in &bootstrap_clone {
                    if !swarm.is_connected(peer_id) {
                        info!("🔄 Reconnexion à {}...", peer_id);
                        let _ = swarm.dial(addr.clone());
                    }
                }
            }

            Some(msg) = ws_to_p2p_rx.recv() => {
                if let Ok(json) = serde_json::to_vec(&msg) {
                    if let Err(e) = swarm.behaviour_mut().gossipsub.publish(topic.clone(), json) {
                        error!("❌ Erreur publication: {:?}", e);
                    } else if let NetworkMessage::Post(ref p) = msg {
                        network_state.add_post(p.clone()).await;
                    }
                }
            }

            Some(post) = post_rx.recv() => {
                let msg = NetworkMessage::Post(post.clone());
                if let Ok(json) = serde_json::to_vec(&msg) {
                    if let Err(e) = swarm.behaviour_mut().gossipsub.publish(topic.clone(), json) {
                        error!("❌ Erreur publication: {:?}", e);
                    } else {
                        info!("📤 Post publié: {}", post.content);
                        network_state.add_post(post).await;
                    }
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
                        message, ..
                    })) => {
                        if let Ok(msg) = serde_json::from_slice::<NetworkMessage>(&message.data) {
                            if let NetworkMessage::Post(post) = msg {
                                info!("📨 Post de {}: {}", post.author_name, post.content);
                                network_state.add_post(post).await;
                            }
                        }
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

                    SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                        info!("✅ Connecté: {}", peer_id);
                        swarm.behaviour_mut().gossipsub.add_explicit_peer(&peer_id);
                        network_state.add_peer(PeerInfo {
                            peer_id: peer_id.to_string(),
                            address: String::new(),
                            name: None,
                            is_browser: false,
                        }).await;
                    }

                    SwarmEvent::ConnectionClosed { peer_id, .. } => {
                        info!("❌ Déconnecté: {}", peer_id);
                        network_state.remove_peer(&peer_id.to_string()).await;
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

fn load_bootstrap_peers() -> Vec<(PeerId, Multiaddr)> {
    let path = "bootstrap.txt";
    let mut peers = Vec::new();
    
    if !Path::new(path).exists() {
        let example = "# Bootstrap peers Zeta Network\n# Format: /ip4/IP/tcp/4001/p2p/PEER_ID\n";
        let _ = fs::write(path, example);
        return peers;
    }

    if let Ok(file) = fs::File::open(path) {
        for line in BufReader::new(file).lines().flatten() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Ok(addr) = line.parse::<Multiaddr>() {
                if let Some(peer_id) = extract_peer_id(&addr) {
                    peers.push((peer_id, addr));
                }
            }
        }
    }

    peers
}

fn extract_peer_id(addr: &Multiaddr) -> Option<PeerId> {
    addr.iter().find_map(|p| {
        if let libp2p::multiaddr::Protocol::P2p(hash) = p {
            PeerId::from_multihash(hash).ok()
        } else {
            None
        }
    })
}
