#!/usr/bin/env python3
"""
Zeta Network - Web Frontend (PythonAnywhere)
Sert l'interface web qui se connecte aux relais P2P via WebSocket
"""

import os
from flask import Flask, render_template, jsonify

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'zeta-dev-key')

# Liste des relais publics - METTEZ VOS RELAIS ICI
# Après avoir lancé install-relay.sh sur un VPS, ajoutez son URL wss://
RELAYS = [
    {"name": "EU 1", "ws": "wss://simpsons-penetration-jackets-lightnings.trycloudflare.com/ws", "api": "https://simpsons-penetration-jackets-lightnings.trycloudflare.com"},
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
