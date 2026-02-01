# Zeta Network - PythonAnywhere

Frontend web pour zetanetwork.org

## Déploiement

1. **Créer un compte** sur [pythonanywhere.com](https://www.pythonanywhere.com)

2. **Cloner le repo** dans la console Bash :
   ```bash
   git clone https://github.com/cTHE0/zeta-network.git
   ```

3. **Configurer l'app web** :
   - Web → Add new web app → Flask → Python 3.10
   - Source code: `/home/VOTRE_USER/zeta-network/pythonanywhere`
   - WSGI file: pointer vers `app.py`

4. **Ajouter vos relais** dans `app.py` :
   ```python
   RELAYS = [
       {"name": "EU 1", "ws": "ws://IP_VPS:3030/ws", "api": "http://IP_VPS:3030"},
   ]
   ```

5. **Reload** l'application

## Domaine custom

Pour utiliser zetanetwork.org :
- Compte PythonAnywhere payant requis
- Configurer le DNS pour pointer vers pythonanywhere
