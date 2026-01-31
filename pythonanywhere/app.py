#!/usr/bin/env python3
"""
Zeta Network - Serveur Web PythonAnywhere
Interface web pour le réseau social P2P décentralisé
"""

from flask import Flask, render_template, jsonify, request
import os
import json
from datetime import datetime

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'zeta-network-dev-key-change-in-production')

# Configuration - Relais publics
RELAYS = [
    '/dns4/wrtc-star1.par.dwebops.pub/tcp/443/wss/p2p-webrtc-star',
    '/dns4/wrtc-star2.sjc.dwebops.pub/tcp/443/wss/p2p-webrtc-star',
    # Ajoutez vos relais Rust ici :
    # '/ip4/VOTRE_VPS_IP/tcp/443/wss/p2p/VOTRE_PEER_ID'
]

@app.route('/')
def home():
    """Page d'accueil"""
    return render_template('index.html')

@app.route('/app')
def p2p_app():
    """Interface P2P complète"""
    return render_template('app.html', relays=json.dumps(RELAYS))

@app.route('/install')
def install():
    """Page d'installation"""
    return render_template('install.html')

@app.route('/api/network-info')
def network_info():
    """API - Informations réseau"""
    return jsonify({
        'relays': RELAYS,
        'topic': '/zeta2/social/v1',
        'max_post_length': 280,
        'version': '1.0.0'
    })

@app.route('/api/stats')
def stats():
    """API - Statistiques (fictives pour l'UX)"""
    return jsonify({
        'active_peers': 42,
        'total_posts': 1289,
        'online_relays': len(RELAYS),
        'network_status': 'operational'
    })

@app.route('/health')
def health():
    """Health check"""
    return jsonify({'status': 'ok', 'timestamp': datetime.utcnow().isoformat()})

@app.errorhandler(404)
def not_found(e):
    """Gestion 404"""
    return render_template('index.html'), 404

@app.errorhandler(500)
def server_error(e):
    """Gestion 500"""
    return jsonify({'error': 'Internal server error'}), 500

if __name__ == '__main__':
    # Pour le développement local
    app.run(host='0.0.0.0', port=5000, debug=True)