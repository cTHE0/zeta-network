#!/usr/bin/env python3
"""
Zeta Network - Web Frontend (PythonAnywhere)
Sert l'interface web qui se connecte aux relais P2P via WebSocket
"""

import os
from flask import Flask, render_template, jsonify

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'zeta-dev-key')

# Liste des relais publics
# Après avoir lancé install-relay.sh sur un VPS, ajoutez l'IP:port
RELAYS = [
    {"name": "EU 1", "ws": "ws://65.75.201.11:3030/ws", "api": "http://65.75.201.11:3030"},
    {"name": "EU 2", "ws": "ws://65.75.200.180:3030/ws", "api": "http://65.75.200.180:3030"},
]

@app.route('/')
def home():
    return render_template('index.html')

@app.route('/app')
def p2p_app():
    return render_template('app.html')

@app.route('/install')
def install():
    return render_template('install.html')

@app.route('/api/relays')
def get_relays():
    return jsonify(RELAYS)

@app.route('/api/info')
def info():
    return jsonify({
        'topic': 'zeta2-social',
        'version': '2.0.0',
        'relays': len(RELAYS)
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
