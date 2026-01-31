//! Serveur web avec WebSocket pour clients navigateur
use crate::{NetworkMessage, NetworkState, PeerInfo, Post};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::convert::Infallible;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};
use warp::ws::{Message, WebSocket};
use warp::{Filter, Rejection, Reply};

#[derive(Serialize)]
struct NetworkInfo {
    local_peer_id: String,
    local_name: String,
    peers: Vec<PeerInfo>,
    posts: Vec<Post>,
    is_relay: bool,
}

#[derive(Deserialize)]
struct PostRequest {
    content: String,
    author_name: String,
}

#[derive(Deserialize)]
struct WsMessage {
    #[serde(rename = "type")]
    msg_type: String,
    content: Option<String>,
    author_name: Option<String>,
}

type SharedState = Arc<RwLock<(NetworkState, mpsc::UnboundedSender<Post>, mpsc::UnboundedSender<NetworkMessage>, String, bool)>>;

pub async fn start_server(
    network_state: NetworkState,
    post_tx: mpsc::UnboundedSender<Post>,
    ws_to_p2p_tx: mpsc::UnboundedSender<NetworkMessage>,
    local_name: String,
    is_relay: bool,
    port: u16,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let shared_state = Arc::new(RwLock::new((
        network_state.clone(),
        post_tx,
        ws_to_p2p_tx,
        local_name,
        is_relay,
    )));

    // Route pour fichiers statiques
    let static_files = warp::fs::dir("./static");

    // Route API - État du réseau
    let state = shared_state.clone();
    let network_info = warp::path("api")
        .and(warp::path("network"))
        .and(warp::get())
        .and(with_state(state))
        .and_then(get_network_info);

    // Route API - Créer un post
    let state = shared_state.clone();
    let post_message = warp::path("api")
        .and(warp::path("post"))
        .and(warp::post())
        .and(warp::body::json())
        .and(with_state(state))
        .and_then(create_post);

    // Route WebSocket
    let ws_state = network_state.clone();
    let ws_p2p_tx = shared_state.clone();
    let websocket = warp::path("ws")
        .and(warp::ws())
        .and(warp::any().map(move || ws_state.clone()))
        .and(warp::any().map(move || ws_p2p_tx.clone()))
        .map(|ws: warp::ws::Ws, state: NetworkState, p2p_state: SharedState| {
            ws.on_upgrade(move |socket| handle_websocket(socket, state, p2p_state))
        });

    // Route pour WASM
    let pkg_files = warp::path("pkg").and(warp::fs::dir("./static/pkg"));

    // CORS
    let cors = warp::cors()
        .allow_any_origin()
        .allow_methods(vec!["GET", "POST", "OPTIONS"])
        .allow_headers(vec!["Content-Type"]);

    let routes = websocket
        .or(pkg_files)
        .or(static_files)
        .or(network_info)
        .or(post_message)
        .with(cors);

    tracing::info!("🌐 Serveur web démarré sur http://localhost:{}", port);
    tracing::info!("🔌 WebSocket disponible sur ws://localhost:{}/ws", port);

    warp::serve(routes).run(([0, 0, 0, 0], port)).await;

    Ok(())
}

fn with_state(state: SharedState) -> impl Filter<Extract = (SharedState,), Error = Infallible> + Clone {
    warp::any().map(move || state.clone())
}

async fn get_network_info(state: SharedState) -> Result<impl Reply, Rejection> {
    let state_guard = state.read().await;
    let (network_state, _, _, local_name, is_relay) = &*state_guard;
    
    let peers_map = network_state.peers.read().await;
    let peers: Vec<PeerInfo> = peers_map.values().cloned().collect();
    let posts = network_state.posts.read().await.clone();

    let info = NetworkInfo {
        local_peer_id: network_state.local_peer_id.to_string(),
        local_name: local_name.clone(),
        peers,
        posts,
        is_relay: *is_relay,
    };

    Ok(warp::reply::json(&info))
}

async fn create_post(
    post_req: PostRequest,
    state: SharedState,
) -> Result<impl Reply, Rejection> {
    use chrono::Utc;
    use uuid::Uuid;
    
    let state_guard = state.read().await;
    let (network_state, post_tx, _, _, _) = &*state_guard;

    let post = Post {
        id: Uuid::new_v4().to_string(),
        author: network_state.local_peer_id.to_string(),
        author_name: post_req.author_name,
        content: post_req.content,
        timestamp: Utc::now().timestamp(),
    };

    if let Err(e) = post_tx.send(post.clone()) {
        tracing::error!("❌ Erreur envoi post au swarm: {}", e);
    }

    tracing::info!("📝 Post créé via REST: {} - {}", post.author_name, post.content);

    Ok(warp::reply::json(&post))
}

/// Gestion d'une connexion WebSocket
async fn handle_websocket(
    ws: WebSocket,
    network_state: NetworkState,
    p2p_state: SharedState,
) {
    let (mut ws_tx, mut ws_rx) = ws.split();
    let browser_peer_id = format!("browser-{}", &uuid::Uuid::new_v4().to_string()[..8]);

    tracing::info!("🌐 Nouveau client WebSocket connecté: {}", browser_peer_id);

    // Ajouter ce client aux peers
    network_state.add_peer(PeerInfo {
        peer_id: browser_peer_id.clone(),
        address: "websocket".to_string(),
        name: Some("Navigateur".to_string()),
        is_browser: true,
    }).await;

    // S'abonner aux broadcasts
    let mut broadcast_rx = network_state.ws_broadcast.subscribe();

    // Envoyer l'état initial
    let initial_state = {
        let peers = network_state.peers.read().await;
        let posts = network_state.posts.read().await;
        serde_json::json!({
            "type": "init",
            "peer_id": browser_peer_id,
            "peers": peers.values().collect::<Vec<_>>(),
            "posts": posts.clone()
        })
    };

    if ws_tx.send(Message::text(initial_state.to_string())).await.is_err() {
        tracing::error!("❌ Erreur envoi état initial");
        return;
    }

    // Boucle principale
    loop {
        tokio::select! {
            // Message du client WebSocket
            msg = ws_rx.next() => {
                match msg {
                    Some(Ok(msg)) => {
                        if msg.is_text() {
                            if let Ok(text) = msg.to_str() {
                                tracing::debug!("📥 Message WebSocket reçu: {}", text);
                                if let Ok(ws_msg) = serde_json::from_str::<WsMessage>(text) {
                                    match ws_msg.msg_type.as_str() {
                                        "post" => {
                                            if let (Some(content), Some(author_name)) = (ws_msg.content, ws_msg.author_name) {
                                                let post = Post {
                                                    id: uuid::Uuid::new_v4().to_string(),
                                                    author: browser_peer_id.clone(),
                                                    author_name: author_name.clone(),
                                                    content: content.clone(),
                                                    timestamp: chrono::Utc::now().timestamp(),
                                                };
                                                
                                                // Ajouter aux posts locaux
                                                {
                                                    let mut posts = network_state.posts.write().await;
                                                    posts.insert(0, post.clone());
                                                    if posts.len() > 100 {
                                                        posts.truncate(100);
                                                    }
                                                }
                                                 
                                                // Broadcast à tous les clients WebSocket
                                                let broadcast_msg = serde_json::json!({
                                                    "type": "new_post",
                                                    "post": post
                                                }).to_string();
                                                let _ = network_state.ws_broadcast.send(broadcast_msg);
                                                 
                                                // Relayer au réseau P2P
                                                let state_guard = p2p_state.read().await;
                                                let (_, _, ws_to_p2p_tx, _, _) = &*state_guard;
                                                let _ = ws_to_p2p_tx.send(NetworkMessage::Post(post.clone()));
                                                
                                                tracing::info!("📝 Post WebSocket relayé: {} - {}", author_name, content);
                                            }
                                        }
                                        "ping" => {
                                            let _ = ws_tx.send(Message::text(r#"{"type": "pong"}"#)).await;
                                        }
                                        _ => {
                                            tracing::debug!("⚠️ Type de message inconnu: {}", ws_msg.msg_type);
                                        }
                                    }
                                } else {
                                    tracing::warn!("⚠️ Message WebSocket invalide: {}", text);
                                }
                            }
                        } else if msg.is_close() {
                            tracing::info!("🚪 Client demande fermeture WebSocket");
                            break;
                        } else if msg.is_ping() {
                            let _ = ws_tx.send(Message::pong(msg.into_bytes())).await;
                        }
                    }
                    Some(Err(e)) => {
                        tracing::error!("❌ Erreur WebSocket: {}", e);
                        break;
                    }
                    None => break,
                }
            }
            
            // Broadcast depuis le réseau P2P
            broadcast = broadcast_rx.recv() => {
                match broadcast {
                    Ok(msg) => {
                        if ws_tx.send(Message::text(msg)).await.is_err() {
                            break;
                        }
                    }
                    Err(_) => {
                        break;
                    }
                }
            }
        }
    }

    // Retirer ce client
    network_state.remove_peer(&browser_peer_id).await;
    tracing::info!("👋 Client WebSocket déconnecté: {}", browser_peer_id);
}