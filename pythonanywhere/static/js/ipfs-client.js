/**
 * Zeta Network - Client IPFS dans le navigateur
 */

class ZetaIPFSClient {
    constructor(config) {
        this.config = config;
        this.ipfs = null;
        this.peerId = null;
        this.posts = [];
        this.peers = new Map();
        this.postIds = new Set();
        this.maxPosts = 150;
        
        this.onStatusChange = null;
        this.onPostReceived = null;
        this.onPeerJoined = null;
        this.onPeerLeft = null;
    }

    async init() {
        try {
            this.updateStatus('🔄 Chargement d\'IPFS...', 'connecting');
            
            const { create } = await import('https://unpkg.com/ipfs@0.6.0/dist/index.min.js');
            
            this.updateStatus('⚙️ Initialisation du nœud IPFS...', 'connecting');

            this.ipfs = await create({
                repo: 'zetanetwork-browser-' + Date.now(),
                config: {
                    Addresses: {
                        Swarm: this.config.bootstrapRelays
                    },
                    Relay: { 
                        Enabled: true, 
                        Hop: { Enabled: false } 
                    },
                    Pubsub: { 
                        Enabled: true,
                        Router: 'gossipsub'
                    }
                },
                EXPERIMENTAL: {
                    pubsub: true
                }
            });

            const id = await this.ipfs.id();
            this.peerId = id.id;
            console.log('✅ IPFS démarré - PeerID:', this.peerId);

            this.updateStatus('🔗 Connexion aux relais...', 'connecting');

            let connectedCount = 0;
            for (const addr of this.config.bootstrapRelays) {
                try {
                    if (addr.includes('p2p-webrtc-star')) continue;
                    await this.ipfs.swarm.connect(addr);
                    connectedCount++;
                    console.log('✅ Connecté:', addr);
                } catch (e) {
                    console.warn('⚠️ Échec connexion:', addr, '-', e.message);
                }
            }

            this.updateStatus('📡 Abonnement au réseau social...', 'connecting');
            await this.ipfs.pubsub.subscribe(this.config.topic, this.handleMessage.bind(this));
            console.log('📡 Abonné au topic:', this.config.topic);

            setInterval(() => this.sendHeartbeat(), this.config.heartbeatInterval);
            this.sendHeartbeat();

            this.updateStatus('✅ Connecté au réseau Zeta', 'online');
            this.updateStatusUI();
            
            this.loadExamplePosts();
            
            return true;

        } catch (error) {
            console.error('❌ Erreur IPFS:', error);
            this.handleError(error);
            return false;
        }
    }

    sendHeartbeat() {
        if (!this.ipfs || !this.peerId) return;
        
        const msg = JSON.stringify({
            type: 'heartbeat',
            peerId: this.peerId,
            timestamp: Date.now()
        });
        
        this.ipfs.pubsub.publish(this.config.topic, msg).catch(() => {});
    }

    handleMessage(msg) {
        try {
            const data = JSON.parse(new TextDecoder().decode(msg.data));
            
            if (data.type === 'post' && data.post) {
                this.handlePostMessage(data.post);
            } else if (data.type === 'heartbeat' && data.peerId) {
                this.handleHeartbeat(data.peerId);
            }
        } catch (e) {
            // Silencieux - messages malformés ignorés
        }
    }

    handlePostMessage(post) {
        if (!post.id || !post.content || !post.author || this.postIds.has(post.id)) {
            return;
        }

        post.content = (post.content || '').trim().substring(0, this.config.maxPostLength);
        post.authorName = (post.authorName || 'Anonyme').trim().substring(0, 24);
        
        if (!post.content) return;

        this.postIds.add(post.id);
        this.posts.unshift(post);
        
        if (this.posts.length > this.maxPosts) {
            const removed = this.posts.pop();
            this.postIds.delete(removed.id);
        }

        if (this.onPostReceived) {
            this.onPostReceived(post);
        }
        
        this.updateStatusUI();
    }

    handleHeartbeat(peerId) {
        const now = Date.now();
        this.peers.set(peerId, { lastSeen: now });
        
        this.peers.forEach((v, k) => {
            if (now - v.lastSeen > this.config.peerTimeout) {
                this.peers.delete(k);
                if (this.onPeerLeft) {
                    this.onPeerLeft(k);
                }
            }
        });
        
        if (this.onPeerJoined && !this.peers.has(peerId)) {
            this.onPeerJoined(peerId);
        }
        
        this.updateStatusUI();
    }

    async publishPost(content, authorName = 'Anonyme') {
        if (!this.ipfs || !content) return null;

        const post = {
            id: 'post-' + Date.now() + '-' + Math.random().toString(36).substr(2, 9),
            author: this.peerId || 'local',
            authorName: authorName.substring(0, 24),
            content: content.substring(0, this.config.maxPostLength),
            timestamp: Date.now()
        };

        const msg = JSON.stringify({ type: 'post', post });
        
        try {
            await this.ipfs.pubsub.publish(this.config.topic, msg);
        } catch (e) {
            console.warn('⚠️ Échec publication réseau:', e.message);
        }
        
        this.handlePostMessage(post);
        
        return post;
    }

    loadExamplePosts() {
        const examples = [
            {
                id: 'welcome-1',
                author: 'system',
                authorName: 'Zeta Network',
                content: '🎉 Bienvenue sur Zeta Network !\n\nPubliez votre premier message et rejoignez la conversation décentralisée. Vos données restent sur votre appareil - pas de serveur central, pas de tracking.',
                timestamp: Date.now() - 300000
            },
            {
                id: 'welcome-2',
                author: 'system',
                authorName: 'Fonctionnalités',
                content: '✨ Ce que vous pouvez faire :\n\n• Publier des messages anonymes ou avec un pseudonyme\n• Voir les posts des autres utilisateurs en temps réel\n• Aucun compte requis\n• Vos données ne quittent jamais votre navigateur',
                timestamp: Date.now() - 240000
            }
        ];
        
        examples.forEach(post => {
            this.postIds.add(post.id);
            this.posts.push(post);
            if (this.onPostReceived) {
                this.onPostReceived(post);
            }
        });
    }

    updateStatus(message, type = 'connecting') {
        if (this.onStatusChange) {
            this.onStatusChange(message, type);
        }
    }

    updateStatusUI() {
        if (typeof window !== 'undefined') {
            const countEl = document.getElementById('peersCount');
            const postsEl = document.getElementById('postsCount');
            const peerIdEl = document.getElementById('peerIdShort');
            
            if (countEl) countEl.textContent = this.peers.size;
            if (postsEl) postsEl.textContent = this.posts.length;
            if (peerIdEl && this.peerId) {
                peerIdEl.textContent = this.peerId.substring(2, 10) + '...';
            }
        }
    }

    handleError(error) {
        let message = '❌ Erreur de connexion au réseau P2P';
        let type = 'offline';
        
        if (error.message.includes('WebRTC') || error.message.includes('ICE')) {
            message = '🔒 Votre navigateur/réseau bloque WebRTC';
        } else if (error.message.includes('timeout')) {
            message = '⏱️ Timeout de connexion';
        }
        
        this.updateStatus(message, type);
        
        setTimeout(() => {
            if (typeof window !== 'undefined') {
                document.getElementById('app').style.display = 'none';
                document.getElementById('fallback').style.display = 'block';
                document.getElementById('status').style.display = 'none';
            }
        }, 2000);
    }

    getPeerList() {
        return Array.from(this.peers.keys());
    }

    getPosts() {
        return [...this.posts];
    }
}