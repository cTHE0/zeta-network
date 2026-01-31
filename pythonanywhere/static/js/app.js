/**
 * Zeta Network - Logique principale de l'application
 */

let zetaClient = null;
let authorName = localStorage.getItem('zeta_author_name') || '';

const elements = {
    status: document.getElementById('status'),
    app: document.getElementById('app'),
    feed: document.getElementById('feed'),
    peersList: document.getElementById('peers'),
    authorNameInput: document.getElementById('authorName'),
    postContent: document.getElementById('postContent'),
    publishBtn: document.getElementById('publishBtn'),
    charCount: document.getElementById('charCount')
};

async function initApp() {
    zetaClient = new ZetaIPFSClient(CONFIG);
    
    zetaClient.onStatusChange = updateStatus;
    zetaClient.onPostReceived = addPostToFeed;
    zetaClient.onPeerJoined = updatePeersList;
    zetaClient.onPeerLeft = updatePeersList;
    
    elements.authorNameInput.value = authorName;
    
    const success = await zetaClient.init();
    
    if (success) {
        elements.app.style.display = 'block';
    }
}

function updateStatus(text, type = 'connecting') {
    const el = elements.status;
    const dot = el.querySelector('.status-dot') || document.createElement('div');
    dot.className = `status-dot status-${type}`;
    
    if (!el.querySelector('.status-dot')) {
        el.insertBefore(dot, el.firstChild);
    }
    
    el.innerHTML = dot.outerHTML + `<span>${text}</span>`;
}

function addPostToFeed(post) {
    const postEl = document.createElement('div');
    postEl.className = 'post';
    
    const date = new Date(post.timestamp || Date.now());
    const timeStr = date.toLocaleTimeString([], { 
        hour: '2-digit', 
        minute: '2-digit',
        hour12: false 
    });

    postEl.innerHTML = `
        <div class="post-header">
            <div class="post-author">${escapeHtml(post.authorName)}</div>
            <div class="post-timestamp">${timeStr}</div>
        </div>
        <div class="post-content">${formatContent(post.content)}</div>
    `;
    
    elements.feed.insertBefore(postEl, elements.feed.firstChild);
}

function formatContent(text) {
    return escapeHtml(text)
        .replace(/\n/g, '<br>')
        .replace(/(https?:\/\/[^\s]+)/g, '<a href="$1" target="_blank" style="color:#6366f1;text-decoration:underline">$1</a>');
}

function escapeHtml(text) {
    if (typeof text !== 'string') return '';
    return text.replace(/[&<>"']/g, m => 
        ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m])
    );
}

async function publishPost() {
    const content = elements.postContent.value.trim();
    const name = elements.authorNameInput.value.trim() || 'Anonyme';
    
    if (!content || content.length > CONFIG.maxPostLength) return;

    localStorage.setItem('zeta_author_name', name);
    authorName = name;

    await zetaClient.publishPost(content, name);
    
    elements.postContent.value = '';
    updateCharCount();
}

function updateCharCount() {
    const len = elements.postContent.value.length;
    
    elements.charCount.textContent = `${len}/${CONFIG.maxPostLength}`;
    
    if (len > CONFIG.maxPostLength) {
        elements.charCount.className = 'char-count danger';
    } else if (len > CONFIG.maxPostLength * 0.8) {
        elements.charCount.className = 'char-count warning';
    } else {
        elements.charCount.className = 'char-count';
    }
    
    elements.publishBtn.disabled = len === 0 || len > CONFIG.maxPostLength;
}

function updatePeersList() {
    if (!zetaClient) return;
    
    const peers = zetaClient.getPeerList();
    
    if (peers.length === 0) {
        elements.peersList.innerHTML = '<div class="peer-badge">En attente de pairs...</div>';
        return;
    }

    elements.peersList.innerHTML = peers
        .filter(pid => pid !== zetaClient.peerId)
        .slice(0, 15)
        .map(pid => {
            const shortId = pid.substring(2, 8);
            return `<div class="peer-badge" title="${pid}">${shortId}</div>`;
        })
        .join('');
}

elements.publishBtn.addEventListener('click', publishPost);
elements.postContent.addEventListener('input', updateCharCount);
elements.postContent.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        publishPost();
    }
});
elements.authorNameInput.addEventListener('input', (e) => {
    e.target.value = e.target.value.substring(0, 24);
});

document.addEventListener('DOMContentLoaded', initApp);