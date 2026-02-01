//! Serveur web avec WebSocket pour l'interface utilisateur
use crate::{NetworkMessage, NetworkState, PeerInfo, Post};
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::convert::Infallible;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};
use warp::ws::{Message, WebSocket};
use warp::Filter;

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
    data: Option<WsPostData>,
}

#[derive(Deserialize)]
struct WsPostData {
    id: Option<String>,
    author: Option<String>,
    content: Option<String>,
    timestamp: Option<i64>,
}

type SharedState = Arc<RwLock<(
    NetworkState,
    mpsc::UnboundedSender<Post>,
    mpsc::UnboundedSender<NetworkMessage>,
    String,
    bool,
)>>;

pub async fn start_server(
    network_state: NetworkState,
    post_tx: mpsc::UnboundedSender<Post>,
    ws_to_p2p_tx: mpsc::UnboundedSender<NetworkMessage>,
    local_name: String,
    is_relay: bool,
    port: u16,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let shared_state: SharedState = Arc::new(RwLock::new((
        network_state.clone(),
        post_tx,
        ws_to_p2p_tx,
        local_name,
        is_relay,
    )));

    // Route API - État du réseau
    let state_for_api = shared_state.clone();
    let network_info = warp::path!("api" / "network")
        .and(warp::get())
        .and(warp::any().map(move || state_for_api.clone()))
        .and_then(get_network_info);

    // Route API - Créer un post
    let state_for_post = shared_state.clone();
    let post_message = warp::path!("api" / "post")
        .and(warp::post())
        .and(warp::body::json())
        .and(warp::any().map(move || state_for_post.clone()))
        .and_then(create_post);

    // Route WebSocket
    let ws_state = network_state.clone();
    let ws_p2p_state = shared_state.clone();
    let websocket = warp::path("ws")
        .and(warp::ws())
        .and(warp::any().map(move || ws_state.clone()))
        .and(warp::any().map(move || ws_p2p_state.clone()))
        .map(|ws: warp::ws::Ws, state: NetworkState, p2p_state: SharedState| {
            ws.on_upgrade(move |socket| handle_websocket(socket, state, p2p_state))
        });

    // Page HTML principale intégrée
    let index = warp::path::end().map(|| {
        warp::reply::html(include_str!("static/index.html"))
    });

    // CORS
    let cors = warp::cors()
        .allow_any_origin()
        .allow_methods(vec!["GET", "POST", "OPTIONS"])
        .allow_headers(vec!["Content-Type"]);

    let routes = websocket
        .or(network_info)
        .or(post_message)
        .or(index)
        .with(cors);

    tracing::info!("🌐 Serveur web sur http://localhost:{}", port);
    tracing::info!("🔌 WebSocket sur ws://localhost:{}/ws", port);

    warp::serve(routes).run(([0, 0, 0, 0], port)).await;
    Ok(())
}

async fn get_network_info(state: SharedState) -> Result<impl warp::Reply, Infallible> {
    let state_guard = state.read().await;
    let (network_state, _, _, local_name, is_relay) = &*state_guard;

    let peers: Vec<PeerInfo> = network_state.peers.read().await.values().cloned().collect();
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

async fn create_post(post_req: PostRequest, state: SharedState) -> Result<impl warp::Reply, Infallible> {
    let state_guard = state.read().await;
    let (network_state, post_tx, _, _, _) = &*state_guard;

    let post = Post {
        id: uuid::Uuid::new_v4().to_string(),
        author: network_state.local_peer_id.to_string(),
        author_name: post_req.author_name,
        content: post_req.content,
        timestamp: chrono::Utc::now().timestamp(),
    };

    let _ = post_tx.send(post.clone());
    tracing::info!("📝 Post créé via REST: {}", post.content);

    Ok(warp::reply::json(&post))
}

async fn handle_websocket(ws: WebSocket, network_state: NetworkState, p2p_state: SharedState) {
    let (mut ws_tx, mut ws_rx) = ws.split();
    let browser_peer_id = format!("browser-{}", &uuid::Uuid::new_v4().to_string()[..8]);

    tracing::info!("🌐 Nouveau client WebSocket: {}", browser_peer_id);

    // Ajouter aux peers
    network_state
        .add_peer(PeerInfo {
            peer_id: browser_peer_id.clone(),
            address: "websocket".to_string(),
            name: Some("Navigateur".to_string()),
            is_browser: true,
        })
        .await;

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

    if ws_tx
        .send(Message::text(initial_state.to_string()))
        .await
        .is_err()
    {
        return;
    }

    loop {
        tokio::select! {
            msg = ws_rx.next() => {
                match msg {
                    Some(Ok(msg)) if msg.is_text() => {
                        if let Ok(text) = msg.to_str() {
                            if let Ok(ws_msg) = serde_json::from_str::<WsMessage>(text) {
                                match ws_msg.msg_type.as_str() {
                                    "post" => {
                                        if let Some(data) = ws_msg.data {
                                            let content = data.content.unwrap_or_default();
                                            let author_name = data.author.unwrap_or_else(|| "Anonyme".to_string());
                                            
                                            let post = Post {
                                                id: data.id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
                                                author: browser_peer_id.clone(),
                                                author_name: author_name.clone(),
                                                content: content.clone(),
                                                timestamp: data.timestamp.unwrap_or_else(|| chrono::Utc::now().timestamp_millis()),
                                            };

                                            // Ajouter localement
                                            network_state.add_post(post.clone()).await;

                                            // Relayer au réseau P2P
                                            let state_guard = p2p_state.read().await;
                                            let (_, _, ws_to_p2p_tx, _, _) = &*state_guard;
                                            let _ = ws_to_p2p_tx.send(NetworkMessage::Post(post));

                                            tracing::info!("📝 Post WebSocket: {} - {}", author_name, content);
                                        }
                                    }
                                    "ping" => {
                                        let _ = ws_tx.send(Message::text(r#"{"type":"pong"}"#)).await;
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                    Some(Ok(msg)) if msg.is_close() => break,
                    Some(Err(_)) | None => break,
                    _ => {}
                }
            }

            broadcast = broadcast_rx.recv() => {
                match broadcast {
                    Ok(msg) => {
                        if ws_tx.send(Message::text(msg)).await.is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        }
    }

    network_state.remove_peer(&browser_peer_id).await;
    tracing::info!("👋 Client WebSocket déconnecté: {}", browser_peer_id);
}
