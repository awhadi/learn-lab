// ==================== CONFIG (set by JSP) ====================
// No client-side secret: the lab control API is open by design (see service_api.jsp).
const BASE_URL = window.SERVICES_CONFIG ? window.SERVICES_CONFIG.baseUrl : "";

// Global client-side error logging so failures are visible in the console.
window.addEventListener('error', (e) => {
    console.error('[dashboard] uncaught error:', e.message || e.type, e.filename ? (e.filename + ':' + e.lineno) : '', e.error || '');
});
window.addEventListener('unhandledrejection', (e) => {
    console.error('[dashboard] unhandled promise rejection:', e.reason);
});

// ==================== Theme management ====================
(function () {
    const root = document.documentElement;
    const toggle = document.getElementById("themeToggle");
    const icon = document.getElementById("themeIcon");
    const stored = localStorage.getItem("theme");
    const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    let theme = stored || (prefersDark ? "dark" : "light");
    applyTheme(theme);
    function applyTheme(t) {
        root.setAttribute("data-theme", t);
        localStorage.setItem("theme", t);
        if (toggle) toggle.checked = t === "dark";
        if (icon) icon.innerHTML = t === "dark" ? "☀️" : "🌙";
    }
    if (toggle) toggle.addEventListener("change", () => applyTheme(toggle.checked ? "dark" : "light"));
    if (icon) icon.addEventListener("click", () => {
        const current = root.getAttribute("data-theme");
        applyTheme(current === "dark" ? "light" : "dark");
    });
})();

// ==================== Time display ====================
let clockTimer = null;
function tickClock() {
    const timeElem = document.getElementById('time');
    if (timeElem) timeElem.innerHTML = new Date().toLocaleString();
}
function startTime() {
    tickClock();
    if (clockTimer) clearInterval(clockTimer);
    // Refresh once per second, paused while the tab is hidden.
    clockTimer = setInterval(() => { if (!document.hidden) tickClock(); }, 1000);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) tickClock(); });
}

// ==================== Disclaimer ====================
function showDisclaimer() {
    const d = document.getElementById('disclaimer');
    if (d) { d.style.display = 'block'; document.body.classList.add('disclaimer-open'); setTimeout(() => d.classList.add('show'), 10); }
}
function closeDisclaimer() {
    const d = document.getElementById('disclaimer');
    if (d) { d.classList.remove('show'); setTimeout(() => { d.style.display = 'none'; document.body.classList.remove('disclaimer-open'); }, 300); }
}
function acceptDisclaimer() {
    localStorage.setItem('disclaimerAccepted', 'true');
    closeDisclaimer();
    document.body.style.overflow = 'auto';
}

// Server-side, IP-keyed tracking (see service_api.jsp's track_access action) —
// localStorage only ever counted "this browser" and reset on a clear, so it
// couldn't recognize the same visitor coming back on a different device.
function trackAccess() {
    const els = {
        ip: document.getElementById('displayIp'),
        device: document.getElementById('displayDevice'),
        first: document.getElementById('displayFirstAccess'),
        last: document.getElementById('displayLastAccess'),
        lastDevice: document.getElementById('displayLastDevice'),
        count: document.getElementById('displayAccessCount'),
        unique: document.getElementById('displayUniqueVisitors')
    };
    fetch('/service_api.jsp?action=track_access', { method: 'POST', cache: 'no-store' })
        .then(r => r.json())
        .then(data => {
            if (!data.success) throw new Error(data.error || 'unknown error');
            if (els.ip) els.ip.textContent = data.ip;
            if (els.device) els.device.textContent = data.device;
            if (els.first) els.first.textContent = new Date(data.firstAccess).toLocaleString();
            if (els.last) els.last.textContent = new Date(data.lastAccess).toLocaleString();
            if (els.lastDevice) els.lastDevice.textContent = data.lastDevice;
            if (els.count) els.count.textContent = data.count;
            if (els.unique) els.unique.textContent = data.uniqueVisitors;
        })
        .catch(err => {
            console.error('[dashboard] trackAccess failed:', err);
            Object.values(els).forEach(el => { if (el) el.textContent = 'Unavailable'; });
        });
}

function checkDisclaimerStatus() {
    if (localStorage.getItem('disclaimerAccepted') !== 'true') {
        document.body.style.overflow = 'hidden';
        setTimeout(showDisclaimer, 500);
    }
}

// ==================== API Functions ====================
function callServiceAPI(params) {
    const method = params.action === 'list_services' ? 'GET' : (params.action === 'add_service' || params.action === 'update_service' || params.action === 'delete_service' ? 'POST' : (params.action === 'status' || params.action === 'logs' || params.action === 'system_stats' ? 'GET' : 'POST'));
    const qs = new URLSearchParams();
    for (const [key, value] of Object.entries(params)) {
        qs.set(key, value);
    }
    // POST parameters travel in the request body (settings import can be large).
    const q = qs.toString();
    const url = (method === 'GET' && q) ? `/service_api.jsp?${q}` : '/service_api.jsp';
    const init = { method: method };
    if (method === 'POST') {
        init.headers = { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' };
        init.body = q;
    }
    return fetch(url, init)
        .then(r => {
            if (!r.ok) {
                const httpErr = new Error('HTTP ' + r.status + ' ' + r.statusText);
                console.error('[service-api] request failed:', url, 'params=', params, httpErr);
                throw httpErr;
            }
            return r.json().catch(jsonErr => {
                console.error('[service-api] invalid JSON response from:', url, jsonErr);
                throw jsonErr;
            });
        })
        .catch(err => {
            console.error('[service-api] call failed:', params && params.action, url, err);
            throw err;
        });
}

// ==================== Settings Modal (Admin Panel) ====================
let currentEditingServiceId = null;
let currentServices = [];
// Core infra entries that must not be deletable from the dashboard.
const DISABLED_DELETE_IDS = ['docker', 'tomcat-service'];

function openSettingsModal() {
    document.getElementById('settingsModal').style.display = 'flex';
    // Freeze the page behind the modal — otherwise the main page and the
    // modal's own list both scroll independently, showing two scrollbars.
    document.body.style.overflow = 'hidden';
    loadServicesList();
    // Tell the truth about the deployed server file before the user picks a file.
    if (window.labCheckImportSupport) window.labCheckImportSupport();
}

function closeSettingsModal() {
    document.getElementById('settingsModal').style.display = 'none';
    document.body.style.overflow = '';
    loadAndRenderServices();
}

function loadServicesList() {
    const container = document.getElementById('servicesList');
    container.innerHTML = '<div class="loading-spinner"><div class="spinner"></div></div>';
    
    callServiceAPI({ action: 'list_services' })
        .then(data => {
            if (data.success && data.config && data.config.services) {
                renderServicesList(data.config.services);
            } else {
                container.innerHTML = '<p class="error">Failed to load services</p>';
            }
        })
        .catch(err => {
            container.innerHTML = '<p class="error">Error: ' + err.message + '</p>';
        });
}

function renderServicesList(services) {
    const container = document.getElementById('servicesList');
    container.innerHTML = '';
    currentServices = services;

    if (!services || services.length === 0) {
        container.innerHTML = '<p class="empty-state">No services configured. Click "Add Service" to get started.</p>';
        return;
    }

    services.forEach((svc, index) => {
        const isInfraDelete = DISABLED_DELETE_IDS.indexOf(svc.id) !== -1;
        const isStatusType = svc.type === 'systemctl' || svc.type === 'docker-compose';
        const item = document.createElement('div');
        item.className = 'service-list-item';
        item.draggable = true;
        item.dataset.id = svc.id;
        // Six independently-positioned pieces (reorder, icon, details, status
        // badge, status action button(s), toggle/edit/delete) are all direct
        // children of .service-list-item, which is a CSS grid. This lets
        // desktop and mobile arrange the exact same elements completely
        // differently (see the max-width:768px rules) using only grid-area,
        // with no DOM difference between breakpoints.
        const statusBadgeHtml = isStatusType
            ? `<span class="svc-status"><span class="svc-status-badge" data-svc="${escapeHtml(svc.id)}" id="svc-status-${escapeHtml(svc.id)}">…</span></span>`
            : '';
        const statusActionsHtml = isStatusType
            ? `<span class="svc-actions" id="svc-actions-${escapeHtml(svc.id)}" data-id="${escapeHtml(svc.id)}"></span>`
            : '';
        item.innerHTML = `
            <div class="service-list-reorder">
                <button class="reorder-btn btn-move-up" data-id="${escapeHtml(svc.id)}" title="Move up" ${index === 0 ? 'disabled' : ''}><i class="fas fa-chevron-up"></i></button>
                <button class="reorder-btn btn-move-down" data-id="${escapeHtml(svc.id)}" title="Move down" ${index === services.length - 1 ? 'disabled' : ''}><i class="fas fa-chevron-down"></i></button>
            </div>
            <div class="service-list-icon"><i class="${escapeHtml(svc.icon || 'fas fa-cube')}"></i></div>
            <div class="service-list-details">
                <h4>${escapeHtml(svc.name)}</h4>
                <p>${escapeHtml(svc.type)} ${svc.manageable ? '• Manageable' : ''}</p>
            </div>
            ${statusBadgeHtml}
            ${statusActionsHtml}
            <div class="service-list-actions">
                <label class="toggle-switch" title="${svc.visible ? 'Hide from main page (service keeps running)' : 'Show on main page (service keeps running)'}">
                    <input type="checkbox" class="visibility-toggle" data-id="${escapeHtml(svc.id)}" data-visible="${escapeHtml(svc.visible)}" ${svc.visible ? 'checked' : ''}>
                    <span class="toggle-slider"></span>
                </label>
                <button class="text-btn btn-edit" data-id="${escapeHtml(svc.id)}" title="Edit ${escapeHtml(svc.name)}"><i class="fas fa-pencil-alt"></i> Edit</button>
                <button class="text-btn btn-delete${isInfraDelete ? ' is-disabled' : ''}" data-id="${escapeHtml(svc.id)}" ${isInfraDelete ? 'disabled' : ''} title="${isInfraDelete ? 'Core service — cannot delete' : 'Delete ' + escapeHtml(svc.name)}" aria-label="${isInfraDelete ? 'Delete disabled for core service' : 'Delete ' + escapeHtml(svc.name)}"><i class="fas fa-times"></i></button>
            </div>
        `;
        container.appendChild(item);
    });

    // Add event listeners
    container.querySelectorAll('.visibility-toggle').forEach(toggle => {
        toggle.addEventListener('change', function() {
            toggleServiceVisibility(this.dataset.id);
        });
    });

    container.querySelectorAll('.btn-edit').forEach(btn => {
        btn.addEventListener('click', function() {
            editService(this.dataset.id);
        });
    });

    container.querySelectorAll('.btn-delete').forEach(btn => {
        if (btn.disabled) return;
        btn.addEventListener('click', function() {
            deleteService(this.dataset.id);
        });
    });

    container.querySelectorAll('.btn-move-up').forEach(btn => {
        btn.addEventListener('click', function() {
            reorderService(this.dataset.id, 'up');
        });
    });

    container.querySelectorAll('.btn-move-down').forEach(btn => {
        btn.addEventListener('click', function() {
            reorderService(this.dataset.id, 'down');
        });
    });

    // Mouse drag & drop reordering (desktop); the up/down buttons stay for touch/keyboard.
    let dragFromIndex = null;
    let dragId = null;
    const rows = Array.prototype.slice.call(container.children);
    rows.forEach(row => {
        row.addEventListener('dragstart', function(e) {
            const idx = rows.indexOf(this);
            dragFromIndex = idx;
            dragId = this.dataset.id || (services[idx] ? services[idx].id : null);
            if (dragId === null) { e.preventDefault(); return; }
            this.classList.add('dragging');
            if (e.dataTransfer) {
                e.dataTransfer.effectAllowed = 'move';
                e.dataTransfer.setData('text/plain', dragId);
            }
        });
        row.addEventListener('dragover', function(e) {
            if (dragFromIndex === null) return;
            e.preventDefault();
            if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
            container.querySelectorAll('.drag-over').forEach(r => r.classList.remove('drag-over'));
            this.classList.add('drag-over');
        });
        row.addEventListener('dragleave', function() {
            this.classList.remove('drag-over');
        });
        row.addEventListener('dragend', function() {
            container.querySelectorAll('.drag-over, .dragging').forEach(r => r.classList.remove('drag-over', 'dragging'));
            dragFromIndex = null;
            dragId = null;
        });
    });
    // Allow the drop anywhere inside the list, then resolve the insertion index
    // from the pointer position against each row's midpoint.
    container.addEventListener('dragover', function(e) {
        if (dragFromIndex === null) return;
        e.preventDefault();
        if (e.dataTransfer) e.dataTransfer.dropEffect = 'move';
    });
    container.addEventListener('drop', function(e) {
        e.preventDefault();
        container.querySelectorAll('.drag-over, .dragging').forEach(r => r.classList.remove('drag-over', 'dragging'));
        if (dragFromIndex === null || dragId === null) { dragFromIndex = null; dragId = null; return; }
        const fromIndex = dragFromIndex;
        const movedId = dragId;
        dragFromIndex = null;
        dragId = null;
        const y = e.clientY;
        let boundary = rows.length;
        for (let i = 0; i < rows.length; i++) {
            const r = rows[i].getBoundingClientRect();
            if (y < r.top + r.height / 2) { boundary = i; break; }
        }
        const toIndex = (boundary > fromIndex) ? boundary - 1 : boundary;
        if (toIndex < 0 || toIndex >= rows.length || toIndex === fromIndex) return;
        reorderServiceTo(movedId, toIndex);
    });

    // Fetch statuses in one batch call; status badges exist only for
    // systemctl / docker-compose rows (never shown as "—" for static).
    fetchAllStatuses();
}

function statusLabel(status) {
    if (status === 'running') return 'running';
    if (status === 'stopped') return 'stopped';
    if (status === 'static' || status === 'not-manageable') return '—';
    return 'unknown';
}

function statusClass(status) {
    if (status === 'running') return 'running';
    if (status === 'stopped') return 'stopped';
    return 'unknown';
}

function fetchAllStatuses() {
    callServiceAPI({ action: 'batch_status' })
        .then(data => {
            if (!data.success || !data.statuses) return;
            for (const [id, status] of Object.entries(data.statuses)) {
                const badge = document.getElementById('svc-status-' + id);
                if (badge) {
                    badge.textContent = statusLabel(status);
                    badge.className = 'svc-status-badge status-' + statusClass(status);
                }
                const svc = currentServices.find(s => s.id === id);
                if (svc) renderRowActions(svc, status);
            }
        })
        .catch(() => {
            currentServices.forEach(svc => {
                const badge = document.getElementById('svc-status-' + svc.id);
                if (badge) { badge.textContent = 'unknown'; badge.className = 'svc-status-badge status-unknown'; }
            });
        });
}

function renderRowActions(svc, status) {
    const slot = document.getElementById('svc-actions-' + svc.id);
    if (!slot) return;
    // Row actions apply to every manageable systemctl/docker-compose service,
    // same as the main-page Manage modal; static services never get a slot
    // rendered here at all (see renderServicesList's isStatusType check).
    const isControllable = svc.manageable && (svc.type === 'systemctl' || svc.type === 'docker-compose');
    if (!isControllable) { slot.innerHTML = ''; return; }
    const actions = Array.isArray(svc.actions) ? svc.actions : [];
    const buttons = [];
    if (status === 'running') {
        if (actions.indexOf('restart') !== -1) buttons.push({ a: 'restart', label: 'Restart', cls: 'btn-restart' });
        // Tomcat must never be stopped from the dashboard (server also rejects it).
        if (svc.id !== 'tomcat-service' && actions.indexOf('stop') !== -1) buttons.push({ a: 'stop', label: 'Stop', cls: 'btn-stop' });
    } else {
        // Stopped or unknown state: offer Start so the row stays actionable.
        if (actions.indexOf('start') !== -1) buttons.push({ a: 'start', label: 'Start', cls: 'btn-start' });
    }
    slot.innerHTML = buttons.map(b =>
        `<button class="svc-action-btn ${b.cls}" data-id="${escapeHtml(svc.id)}" data-action="${b.a}">${b.label}</button>`
    ).join('');
    slot.querySelectorAll('button').forEach(btn => {
        btn.addEventListener('click', () => rowAction(btn.dataset.id, btn.dataset.action, btn));
    });
}

function rowAction(id, action, btn) {
    const svc = currentServices.find(s => s.id === id);
    const name = svc ? svc.name : id;
    if (action === 'stop' || action === 'restart') {
        if (!confirm(`Are you sure you want to ${action} ${name}?`)) return;
    }
    const originalLabel = btn.textContent;
    btn.disabled = true;
    btn.textContent = '…';
    callServiceAPI({ service: id, action: action })
        .then(data => {
            if (data.success) {
                fetchAllStatuses();
            } else {
                alert(`Failed to ${action} ${name}: ${data.error || 'Unknown error'}`);
                btn.disabled = false;
                btn.textContent = originalLabel;
            }
        })
        .catch(err => {
            alert(`Failed to ${action} ${name}: ${err.message}`);
            btn.disabled = false;
            btn.textContent = originalLabel;
        });
}

function reorderService(id, dir) {
    performReorder({ id: id, dir: dir });
}

function reorderServiceTo(id, toIndex) {
    performReorder({ id: id, toIndex: toIndex });
}

function performReorder(params) {
    const body = Object.assign({ action: 'reorder_service' }, params);
    callServiceAPI(body)
        .then(data => {
            if (data.success) {
                loadServicesList();
                loadAndRenderServices();
            } else {
                alert('Failed to reorder: ' + (data.error || 'Unknown'));
            }
        })
        .catch(err => {
            alert('Error reordering: ' + err.message);
        });
}

function toggleServiceVisibility(id) {
    // Show/hide only — this never stops or starts the underlying service.
    callServiceAPI({ action: 'toggle_visible', id: id })
        .then(data => {
            if (!data.success) alert('Failed to update visibility: ' + (data.error || 'Unknown'));
            loadServicesList();
        })
        .catch(err => {
            alert('Error updating visibility: ' + err.message);
            loadServicesList();
        });
}

// Reset is wired by delegation so it keeps working even if part of the page
// initialisation is skipped. Export is a plain link and Import is handled
// inline in index.jsp, so neither depends on this file.
document.addEventListener('click', function(e) {
    const el = (e.target && e.target.closest) ? e.target.closest('#resetServicesBtn') : null;
    if (!el) return;
    e.preventDefault();
    resetServicesToDefault();
});

function resetServicesToDefault() {
    if (!confirm('Reset all services to the default settings?\n\nThis restores the original service list (names, descriptions, order, visibility) and removes any services you added or edited.')) {
        return;
    }
    callServiceAPI({ action: 'reset_services' })
        .then(data => {
            if (data.success) {
                alert('Services have been reset to defaults.');
                loadServicesList();
                loadAndRenderServices();
            } else {
                alert('Reset failed: ' + (data.error || 'Unknown error'));
            }
        })
        .catch(err => {
            alert('Reset failed: ' + err.message);
        });
}

// ==================== Add/Edit Service ====================
// ==================== Icon picker ====================
// A curated subset of the self-hosted FontAwesome set (no extra network
// request — this app already ships the full font) covering the icon
// families actually useful for a lab/infra dashboard. The text input next
// to it still accepts any class, so this is a shortcut, not a restriction.
const ICON_CHOICES = [
    'fas fa-cube', 'fas fa-server', 'fas fa-database', 'fas fa-cogs', 'fas fa-cog',
    'fas fa-globe', 'fas fa-folder-open', 'fas fa-envelope', 'fas fa-code', 'fas fa-terminal',
    'fas fa-chart-bar', 'fas fa-chart-line', 'fas fa-lock', 'fas fa-shield-alt', 'fas fa-cloud',
    'fas fa-key', 'fas fa-file', 'fas fa-desktop', 'fas fa-network-wired', 'fas fa-link',
    'fas fa-table', 'fas fa-exchange-alt', 'fas fa-plug', 'fas fa-wrench', 'fas fa-tools',
    'fas fa-bell', 'fas fa-bug', 'fas fa-flask', 'fas fa-rocket', 'fas fa-layer-group',
    'fas fa-sitemap', 'fas fa-project-diagram', 'fas fa-users', 'fas fa-user', 'fas fa-clock',
    'fas fa-calendar', 'fas fa-search', 'fas fa-filter', 'fas fa-list', 'fas fa-inbox',
    'fas fa-comments', 'fas fa-cloud-upload-alt', 'fas fa-cloud-download-alt', 'fas fa-hdd',
    'fas fa-microchip', 'fas fa-memory',
    'fab fa-docker', 'fab fa-github', 'fab fa-git-alt', 'fab fa-linux', 'fab fa-windows',
    'fab fa-apple', 'fab fa-aws', 'fab fa-google', 'fab fa-react', 'fab fa-node-js',
    'fab fa-python', 'fab fa-java', 'fab fa-php'
];

function updateIconPreview() {
    const value = (document.getElementById('serviceIcon').value || 'fas fa-cube').trim();
    document.getElementById('serviceIconPreview').innerHTML = '<i class="' + escapeHtml(value) + '"></i>';
    document.querySelectorAll('.icon-picker-btn').forEach(btn => {
        btn.classList.toggle('selected', btn.dataset.icon === value);
    });
}

function renderIconPicker() {
    const picker = document.getElementById('iconPicker');
    if (picker.childElementCount > 0) return; // built once, reused
    picker.innerHTML = ICON_CHOICES.map(cls =>
        `<button type="button" class="icon-picker-btn" data-icon="${escapeHtml(cls)}" title="${escapeHtml(cls)}"><i class="${escapeHtml(cls)}"></i></button>`
    ).join('');
    picker.querySelectorAll('.icon-picker-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.getElementById('serviceIcon').value = btn.dataset.icon;
            updateIconPreview();
            closeIconPicker();
        });
    });
}

function closeIconPicker() {
    document.getElementById('iconPicker').style.display = 'none';
}

function toggleIconPicker() {
    const picker = document.getElementById('iconPicker');
    const opening = picker.style.display === 'none';
    if (opening) renderIconPicker();
    picker.style.display = opening ? 'grid' : 'none';
    if (opening) updateIconPreview();
}

// Closes the picker on any click outside it (and outside its own toggle
// button), same as a normal dropdown — otherwise it stayed open while
// filling in the rest of the form.
document.addEventListener('click', function (e) {
    const picker = document.getElementById('iconPicker');
    if (!picker || picker.style.display === 'none') return;
    const toggleBtn = document.getElementById('toggleIconPickerBtn');
    if (picker.contains(e.target) || e.target === toggleBtn) return;
    closeIconPicker();
});

// ==================== Open Links (repeatable label + URL rows) ====================
function createLinkRow(text, url) {
    const row = document.createElement('div');
    row.className = 'link-row';
    row.innerHTML = `
        <input type="text" class="link-label-input" placeholder="Button label (optional)">
        <input type="text" class="link-url-input" placeholder="https://server.com/path or /path">
        <button type="button" class="btn-remove-link" title="Remove this link"><i class="fas fa-times"></i></button>
    `;
    row.querySelector('.link-label-input').value = text || '';
    row.querySelector('.link-url-input').value = url || '';
    row.querySelector('.btn-remove-link').addEventListener('click', () => row.remove());
    return row;
}

function addLinkRow(text = '', url = '') {
    document.getElementById('serviceLinksBox').appendChild(createLinkRow(text, url));
}

function resetLinkRows(links) {
    const box = document.getElementById('serviceLinksBox');
    box.innerHTML = '';
    if (Array.isArray(links) && links.length > 0) {
        links.forEach(l => addLinkRow(l && l.text, l && l.url));
    } else {
        addLinkRow();
    }
}

// Reads the current rows into [{text, url}], skipping rows left without a URL.
function collectLinkRows() {
    return Array.prototype.slice.call(document.querySelectorAll('#serviceLinksBox .link-row'))
        .map(row => ({
            text: row.querySelector('.link-label-input').value.trim(),
            url: row.querySelector('.link-url-input').value.trim()
        }))
        .filter(l => l.url !== '');
}

function openServiceForm(serviceId = null) {
    currentEditingServiceId = serviceId;
    const modal = document.getElementById('serviceFormModal');
    const title = document.getElementById('serviceFormTitle');
    const form = document.getElementById('serviceForm');

    form.reset();
    document.getElementById('serviceFormId').value = '';
    document.getElementById('serviceVisible').checked = true;
    document.getElementById('serviceIcon').value = 'fas fa-cube';
    document.getElementById('iconPicker').style.display = 'none';
    updateIconPreview();
    resetLinkRows(null);
    resetComposePreview();
    const typeSelect = document.getElementById('serviceType');

    if (serviceId) {
        title.textContent = 'Edit Service';
        loadServiceForEdit(serviceId);
        typeSelect.disabled = true;
    } else {
        title.textContent = 'Add Service';
        typeSelect.disabled = false;
        // New services default to Static; management (see checkbox) only applies
        // to systemctl / docker-compose and is enabled when those types are picked.
        typeSelect.value = 'static';
        document.getElementById('serviceManageable').checked = false;
    }
    
    updateServiceTypeFields();
    modal.style.display = 'flex';
}

function closeServiceForm() {
    document.getElementById('serviceFormModal').style.display = 'none';
    currentEditingServiceId = null;
}

function loadServiceForEdit(id) {
    callServiceAPI({ action: 'list_services' })
        .then(data => {
            if (data.success && data.config && data.config.services) {
                const service = data.config.services.find(s => s.id === id);
                if (service) {
                    document.getElementById('serviceFormId').value = service.id;
                    document.getElementById('serviceName').value = service.name || '';
                    document.getElementById('serviceType').value = service.type || 'docker-compose';
                    document.getElementById('serviceIcon').value = service.icon || 'fas fa-cube';
                    updateIconPreview();
                    if (Array.isArray(service.links) && service.links.length > 0) {
                        resetLinkRows(service.links);
                    } else if (service.openUrl) {
                        resetLinkRows([{ text: '', url: service.openUrl }]);
                    } else {
                        resetLinkRows(null);
                    }
                    document.getElementById('serviceDescription').value = service.description || '';
                    document.getElementById('serviceVisible').checked = service.visible;
                    document.getElementById('serviceManageable').checked = service.manageable;
                    
                    if (service.type === 'docker-compose') {
                        document.getElementById('composePath').value = service.composePath || '';
                        document.getElementById('composeOption').value = 'path';
                        updateComposeOptionFields();
                        // Preview stays hidden until the user explicitly asks for it.
                        resetComposePreview();
                    } else if (service.type === 'systemctl') {
                        document.getElementById('systemctlService').value = service.service || '';
                    }
                    
                    updateServiceTypeFields();
                }
            }
        })
        .catch(err => {
            alert('Error loading service: ' + err.message);
        });
}

function updateServiceTypeFields() {
    const type = document.getElementById('serviceType').value;
    document.getElementById('dockerComposeFields').style.display = type === 'docker-compose' ? 'block' : 'none';
    document.getElementById('systemctlFields').style.display = type === 'systemctl' ? 'block' : 'none';
    // The built-in Server Stats widget is self-contained (live numbers, no
    // link to open, no description to write) — those fields don't apply.
    const isStats = type === 'system-stats';
    document.getElementById('openLinksGroup').style.display = isStats ? 'none' : 'block';
    document.getElementById('descriptionGroup').style.display = isStats ? 'none' : 'block';
    syncManageableField(type);
}

function syncManageableField(type) {
    const manageableCheck = document.getElementById('serviceManageable');
    if (!manageableCheck) return;
    const label = document.getElementById('serviceManageableLabel');
    const manageableType = type === 'systemctl' || type === 'docker-compose';
    if (!manageableType) {
        // Management applies only to systemctl / docker-compose services.
        manageableCheck.checked = false;
        manageableCheck.disabled = true;
        if (label) label.classList.add('disabled');
    } else {
        const wasDisabled = manageableCheck.disabled;
        manageableCheck.disabled = false;
        if (label) label.classList.remove('disabled');
        // In the Add flow, picking a manageable type pre-checks the option.
        if (wasDisabled && currentEditingServiceId === null) manageableCheck.checked = true;
    }
}

function updateComposeOptionFields() {
    const option = document.getElementById('composeOption').value;
    document.getElementById('composePathGroup').style.display = option === 'path' ? 'block' : 'none';
    document.getElementById('composeContentGroup').style.display = option === 'content' ? 'block' : 'none';
}

// Resets the preview to its default (hidden) state — called whenever the
// form opens, so a previously-shown preview never carries over.
function resetComposePreview() {
    const preview = document.getElementById('composeFilePreview');
    const btn = document.getElementById('loadComposeFileBtn');
    if (!preview) return;
    preview.textContent = '';
    preview.classList.remove('show', 'is-error');
    if (btn) { btn.disabled = false; btn.textContent = 'Show docker-compose.yml'; }
}

// Toggles the compose-file preview open/closed. Hidden is always the
// starting state (see resetComposePreview); only this button shows it.
function loadComposePreview() {
    const preview = document.getElementById('composeFilePreview');
    const btn = document.getElementById('loadComposeFileBtn');
    if (!preview) return;

    if (preview.classList.contains('show')) {
        preview.classList.remove('show');
        if (btn) btn.textContent = 'Show docker-compose.yml';
        return;
    }

    const path = (document.getElementById('composePath').value || '').trim();
    if (!path) {
        preview.textContent = 'Enter a compose path first.';
        preview.classList.add('show', 'is-error');
        return;
    }
    if (btn) {
        btn.disabled = true;
        btn.textContent = 'Loading…';
    }
    callServiceAPI({ action: 'read_compose_file', composePath: path })
        .then(data => {
            if (btn) { btn.disabled = false; btn.textContent = 'Hide docker-compose.yml'; }
            if (data.success) {
                preview.textContent = '# ' + (data.fileName || 'docker-compose.yml') + '\n\n' + data.content;
                preview.classList.remove('is-error');
            } else {
                preview.textContent = (data.error || 'Could not read the compose file.');
                preview.classList.add('is-error');
            }
            preview.classList.add('show');
        })
        .catch(err => {
            if (btn) { btn.disabled = false; btn.textContent = 'Hide docker-compose.yml'; }
            preview.textContent = 'Failed to load file: ' + err.message;
            preview.classList.add('is-error');
            preview.classList.add('show');
        });
}

function saveService() {
    const form = document.getElementById('serviceForm');
    if (!form.checkValidity()) {
        form.reportValidity();
        return;
    }
    
    const id = document.getElementById('serviceFormId').value;
    const name = document.getElementById('serviceName').value.trim();
    const type = document.getElementById('serviceType').value;
    const icon = document.getElementById('serviceIcon').value.trim();
    const description = document.getElementById('serviceDescription').value;
    const visible = document.getElementById('serviceVisible').checked;
    const manageable = document.getElementById('serviceManageable').checked;
    const links = collectLinkRows();

    const params = {
        action: id ? 'update_service' : 'add_service',
        name: name,
        type: type,
        icon: icon,
        description: description,
        visible: visible,
        manageable: manageable,
        links: JSON.stringify(links)
    };
    
    if (id) params.id = id;
    
    if (type === 'docker-compose') {
        const composeOption = document.getElementById('composeOption').value;
        if (composeOption === 'path') {
            params.composePath = document.getElementById('composePath').value.trim();
        } else {
            params.composeContent = document.getElementById('composeContent').value;
        }
    } else if (type === 'systemctl') {
        params.serviceName = document.getElementById('systemctlService').value.trim();
    }
    
    const saveBtn = document.getElementById('saveServiceBtn');
    saveBtn.disabled = true;
    saveBtn.textContent = 'Saving...';
    
    callServiceAPI(params)
        .then(data => {
            saveBtn.disabled = false;
            saveBtn.textContent = 'Save Service';
            
            if (data.success) {
                closeServiceForm();
                loadServicesList();
            } else {
                alert('Failed to save service: ' + (data.error || 'Unknown error'));
            }
        })
        .catch(err => {
            saveBtn.disabled = false;
            saveBtn.textContent = 'Save Service';
            alert('Error: ' + err.message);
        });
}

function editService(id) {
    openServiceForm(id);
}

function deleteService(id) {
    if (DISABLED_DELETE_IDS.indexOf(id) !== -1) return; // belt & braces: infra rows have disabled buttons
    const svc = currentServices.find(s => s.id === id);
    const name = svc ? svc.name : id;

    function removeFromList() {
        callServiceAPI({ action: 'delete_service', id: id })
            .then(data => {
                if (data.success) {
                    loadServicesList();
                } else {
                    alert('Failed to delete service: ' + (data.error || 'Unknown error'));
                }
            })
            .catch(err => {
                alert('Error: ' + err.message);
            });
    }

    // Removing a row never stops anything and never deletes files; those stay a
    // separate, explicit decision. Only a running service is asked about -- a
    // stopped one is just removed from the list, with no dialog at all.
    probeDeleteStatus(svc).then(status => {
        if (status !== 'running') {
            removeFromList();
            return;
        }
        const stopFirst = confirm(`"${name}" is running.\n\n`
            + 'Do you want to stop it before removing it from the list?\n\n'
            + 'OK = stop the service, then remove it from the list\n'
            + 'Cancel = leave it running, only remove it from the list');
        if (!stopFirst) {
            removeFromList();
            return;
        }
        callServiceAPI({ service: id, action: 'stop' })
            .then(data => {
                if (data.success) return removeFromList();
                if (confirm(`Could not stop "${name}": ${data.error || 'Unknown error'}\n\nRemove it from the list anyway? The service keeps running.`)) {
                    removeFromList();
                }
            })
            .catch(err => {
                if (confirm(`Could not stop "${name}": ${err.message}\n\nRemove it from the list anyway? The service keeps running.`)) {
                    removeFromList();
                }
            });
    });
}

// Fresh status probe for a delete decision: the row badge can be minutes old.
// Non-manageable rows (static links) are never asked about.
function probeDeleteStatus(svc) {
    if (!svc || !svc.manageable || (svc.type !== 'systemctl' && svc.type !== 'docker-compose')) {
        return Promise.resolve('n/a');
    }
    return callServiceAPI({ service: svc.id, action: 'status' })
        .then(data => (data && data.status) ? data.status : 'unknown')
        .catch(() => 'unknown');
}

// ==================== Service Management Modal ====================
let currentService = null;
let currentServiceName = null;

function openServiceModal(service, serviceName) {
    currentService = service;
    currentServiceName = serviceName || null;
    const modal = document.getElementById('serviceModal');
    const titleElem = document.getElementById('modalServiceTitle');
    if (currentServiceName) {
        titleElem.innerText = currentServiceName + ' Management';
    } else {
        // Never show the generated id: resolve the display name from config.
        titleElem.innerText = 'Manage service';
        callServiceAPI({ action: 'list_services' })
            .then(data => {
                const svc = ((data && data.config && data.config.services) || []).find(s => s.id === service);
                if (svc && svc.name) {
                    currentServiceName = svc.name;
                    if (currentService === service) titleElem.innerText = svc.name + ' Management';
                }
            })
            .catch(() => {});
    }
    modal.style.display = 'flex';
    document.getElementById('modalStatusIndicator').className = 'service-status-indicator';
    document.getElementById('modalStatusText').innerText = 'Checking status...';
    document.getElementById('modalButtons').innerHTML = '';
    document.getElementById('modalLogsArea').style.display = 'none';
    fetchStatusAndUpdateModal(service);
}

function closeServiceModal() {
    document.getElementById('serviceModal').style.display = 'none';
    currentService = null;
    currentServiceName = null;
}

function fetchStatusAndUpdateModal(service) {
    callServiceAPI({ service: service, action: 'status' })
        .then(data => {
            if (data.success) {
                const isRunning = data.status === 'running';
                const indicator = document.getElementById('modalStatusIndicator');
                const statusText = document.getElementById('modalStatusText');
                indicator.className = `service-status-indicator ${isRunning ? 'running' : 'stopped'}`;
                statusText.innerText = isRunning ? 'Running' : 'Stopped';
                renderModalButtons(service, isRunning);
            } else {
                document.getElementById('modalStatusText').innerText = 'Error: ' + (data.error || 'Unknown');
            }
        })
        .catch(err => {
            document.getElementById('modalStatusText').innerText = 'Failed to fetch status: ' + err.message;
        });
}

function renderModalButtons(service, isRunning) {
    const container = document.getElementById('modalButtons');
    container.innerHTML = '';
    if (isRunning) {
        // Tomcat can never be stopped from the dashboard (the server also rejects it).
        if (service !== 'tomcat-service') {
            const stopBtn = document.createElement('button');
            stopBtn.className = 'btn-stop';
            stopBtn.innerHTML = '<i class="fas fa-stop"></i> Stop';
            stopBtn.onclick = () => performAction(service, 'stop');
            container.appendChild(stopBtn);
        }
        const restartBtn = document.createElement('button');
        restartBtn.className = 'btn-restart';
        restartBtn.innerHTML = '<i class="fas fa-sync-alt"></i> Restart';
        restartBtn.onclick = () => performAction(service, 'restart');
        container.appendChild(restartBtn);
    } else {
        const startBtn = document.createElement('button');
        startBtn.className = 'btn-start';
        startBtn.innerHTML = '<i class="fas fa-play"></i> Start';
        startBtn.onclick = () => performAction(service, 'start');
        container.appendChild(startBtn);
    }
    const logsBtn = document.createElement('button');
    logsBtn.className = 'btn-logs';
    logsBtn.innerHTML = '<i class="fas fa-scroll"></i> Show Logs';
    logsBtn.onclick = () => fetchLogs(service);
    container.appendChild(logsBtn);

    const editBtn = document.createElement('button');
    editBtn.className = 'btn-edit-service';
    editBtn.innerHTML = '<i class="fas fa-pencil-alt"></i> Edit';
    editBtn.onclick = () => {
        closeServiceModal();
        openServiceForm(service);
    };
    container.appendChild(editBtn);
}

function performAction(service, action) {
    const label = currentServiceName || service;
    if (!confirm(`Are you sure you want to ${action} ${label}?`)) return;
    executeAction(service, action);
}

function executeAction(service, action) {
    const label = currentServiceName || service;
    const loadingModal = document.getElementById('loadingModal');
    const loadingText = document.getElementById('loadingText');
    loadingText.innerText = `${action}ing ${label}...`;
    loadingModal.style.display = 'flex';

    callServiceAPI({ service: service, action: action })
        .then(data => {
            loadingModal.style.display = 'none';
            if (data.success) {
                alert(`${label} ${action} completed successfully.`);
                if (currentService === service) {
                    const delay = action === 'restart' ? 5000 : 2000;
                    setTimeout(() => fetchStatusAndUpdateModal(service), delay);
                }
            } else {
                alert(`Error: ${data.error}`);
            }
        })
        .catch(err => {
            loadingModal.style.display = 'none';
            alert(`Failed: ${err.message}`);
        });
}

function fetchLogs(service) {
    const logsArea = document.getElementById('modalLogsArea');
    const logsContent = document.getElementById('modalLogsContent');
    logsArea.style.display = 'block';
    logsContent.innerText = 'Loading logs...';
    callServiceAPI({ service: service, action: 'logs', lines: '100' })
        .then(data => {
            if (data.success) {
                logsContent.innerText = data.logs;
            } else {
                logsContent.innerText = 'Failed to fetch logs: ' + data.error;
            }
        })
        .catch(err => {
            logsContent.innerText = 'Error: ' + err.message;
        });
}

// ==================== Helper Functions ====================
function escapeHtml(text) {
    // Must also encode quotes: several call sites interpolate this into an
    // HTML attribute (class="...", data-name="...", href="...", not just text
    // content), and an unescaped " lets the value break out of the attribute.
    if (text == null) return '';
    return String(text)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

// Sanitizes HTML that came from the (editable) service config before insertion.
function sanitizeHtml(text) {
    if (typeof DOMPurify !== 'undefined' && text != null) {
        return DOMPurify.sanitize(String(text));
    }
    return escapeHtml(text);
}

function resolveOpenUrl(url) {
    if (!url) return '#';
    const base = BASE_URL || window.location.origin;
    if (/^https?:\/\//i.test(url)) return url;
    // Block every non-http(s) scheme (javascript:, data:, vbscript:, ...).
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(url)) return '#';
    // Relative paths and bare paths (e.g. /test, phpldapadmin) open on the current domain.
    let path = url;
    if (path === '' || path === '.') path = '/';
    if (!path.startsWith('/')) path = '/' + path;
    return base + path;
}

// ==================== Main Page Service Cards ====================
function loadAndRenderServices() {
    const container = document.getElementById('servicesContainer');
    if (!container) return;

    callServiceAPI({ action: 'list_services' })
        .then(data => {
            if (!data.success || !data.config || !data.config.services) {
                container.innerHTML = '<div class="col-md-4"><div class="card"><div class="card-body"><p>Failed to load services.</p></div></div></div>';
                return;
            }

            const visible = data.config.services.filter(s => s.visible !== false);
            if (visible.length === 0) {
                container.innerHTML = '<div class="col-md-4"><div class="card"><div class="card-body"><p>No visible services.</p></div></div></div>';
                return;
            }

            container.innerHTML = '';
            visible.forEach(svc => {
                const card = document.createElement('div');
                card.className = 'col-md-4';

                const canManage = svc.manageable && (svc.type === 'docker-compose' || svc.type === 'systemctl');
                // Support one "Open" target via openUrl, or several explicit links
                // (the Tomcat card exposes both Tomcat Manager and Host Manager).
                const footerLinks = [];
                if (typeof svc.openUrl === 'string' && svc.openUrl.trim() !== '') {
                    footerLinks.push({ url: resolveOpenUrl(svc.openUrl.trim()), text: `Open ${svc.name}` });
                } else if (Array.isArray(svc.links)) {
                    svc.links.forEach(link => {
                        if (link && link.url) footerLinks.push({ url: resolveOpenUrl(String(link.url)), text: link.text || `Open ${svc.name}` });
                    });
                }
                const hasOpen = footerLinks.length > 0;

                const linkButtons = footerLinks.map(l =>
                    `<a href="${escapeHtml(l.url)}" target="_blank" rel="noopener noreferrer" class="card-link-sm"><i class="fas fa-external-link-alt"></i> ${escapeHtml(l.text)}</a>`
                ).join('');

                const footerHtml = (canManage || hasOpen)
                    ? `<div class="card-footer-right">
                        <div class="card-footer-links">${linkButtons}</div>
                        ${canManage ? `<a href="#" class="manage-btn" data-service="${escapeHtml(svc.id)}" data-name="${escapeHtml(svc.name)}"><i class="fas fa-cog"></i> Manage</a>` : ''}
                       </div>`
                    : '';

                // Sanitize only the config-owned description; the card skeleton below is trusted markup.
                const bodyHtml = svc.type === 'system-stats'
                    ? statsCardBodyHtml()
                    : `<div class="card-service-info">${sanitizeHtml(svc.description || '')}</div>`;
                card.innerHTML = `
                    <div class="card">
                        <div class="card-header">
                            <h3 class="card-title"><i class="${escapeHtml(svc.icon || 'fas fa-cube')}"></i> ${escapeHtml(svc.name)}</h3>
                        </div>
                        <div class="card-body">
                            ${bodyHtml}
                        </div>
                        ${footerHtml}
                    </div>
                `;
                container.appendChild(card);
            });

            container.querySelectorAll('.manage-btn').forEach(btn => {
                btn.addEventListener('click', function(e) {
                    e.preventDefault();
                    openServiceModal(this.dataset.service, this.dataset.name);
                });
            });

            // Stats are fetched separately, after the cards are already on
            // screen, so a slow/unavailable metrics call never delays the
            // rest of the page from rendering.
            if (systemStatsRefreshTimer) {
                clearInterval(systemStatsRefreshTimer);
                systemStatsRefreshTimer = null;
            }
            if (container.querySelector('.stats-card-body')) {
                fetchAndRenderSystemStats();
                systemStatsRefreshTimer = setInterval(() => {
                    if (document.visibilityState !== 'hidden') fetchAndRenderSystemStats();
                }, 5000);
            }
        })
        .catch(err => {
            container.innerHTML = `<div class="col-md-4"><div class="card"><div class="card-body"><p>Error loading services: ${escapeHtml(err.message)}</p></div></div></div>`;
        });
}

let systemStatsRefreshTimer = null;

function statsCardBodyHtml() {
    const row = (field, icon, label) => `
        <div class="stats-row">
            <div class="stats-row-header">
                <span class="stats-label"><i class="${icon}"></i> ${label}</span>
                <span class="stats-value" data-stats-field="${field}">…</span>
            </div>
            <div class="stats-bar"><div class="stats-bar-fill" data-stats-fill="${field}" style="width:0%"></div></div>
        </div>`;
    return `<div class="stats-card-body">
        ${row('cpu', 'fas fa-microchip', 'CPU')}
        ${row('mem', 'fas fa-memory', 'Memory')}
        ${row('disk', 'fas fa-hdd', 'Storage')}
    </div>`;
}

function formatGiB(bytes) {
    if (typeof bytes !== 'number' || isNaN(bytes)) return '—';
    return (bytes / 1073741824).toFixed(2) + ' GiB';
}

function setStatRow(root, field, valueText, percent) {
    const valueEl = root.querySelector(`[data-stats-field="${field}"]`);
    const fillEl = root.querySelector(`[data-stats-fill="${field}"]`);
    if (valueEl) valueEl.textContent = valueText;
    if (fillEl) fillEl.style.width = Math.max(0, Math.min(100, percent || 0)) + '%';
}

function fetchAndRenderSystemStats() {
    const cards = document.querySelectorAll('.stats-card-body');
    if (cards.length === 0) return;
    callServiceAPI({ action: 'system_stats' })
        .then(data => {
            if (!data.success || !data.stats) throw new Error(data.error || 'Unavailable');
            const s = data.stats;
            const cpuPct = (typeof s.cpuPercent === 'number') ? s.cpuPercent : null;
            const memPct = s.memTotalBytes ? (s.memUsedBytes / s.memTotalBytes * 100) : 0;
            const diskPct = s.diskTotalBytes ? (s.diskUsedBytes / s.diskTotalBytes * 100) : 0;
            cards.forEach(root => {
                setStatRow(root, 'cpu', cpuPct !== null ? cpuPct.toFixed(2) + '%' : 'n/a', cpuPct);
                setStatRow(root, 'mem', `${formatGiB(s.memUsedBytes)} / ${formatGiB(s.memTotalBytes)}`, memPct);
                setStatRow(root, 'disk', `${formatGiB(s.diskUsedBytes)} / ${formatGiB(s.diskTotalBytes)}`, diskPct);
            });
        })
        .catch(() => {
            cards.forEach(root => {
                root.querySelectorAll('.stats-value').forEach(el => { el.textContent = 'Unavailable'; });
            });
        });
}

// ==================== Initialization ====================
document.addEventListener('DOMContentLoaded', function() {

    // --- Load service cards dynamically ---
    loadAndRenderServices();

    // The stats card's own interval pauses while this tab is in the
    // background; without this, coming back to the tab shows numbers as
    // stale as however long it was hidden, which reads as "not live".
    document.addEventListener('visibilitychange', function() {
        if (document.visibilityState === 'visible') fetchAndRenderSystemStats();
    });

    // --- Close service modal button ---
    const closeServiceModalBtn = document.getElementById('closeServiceModalBtn');
    if (closeServiceModalBtn) {
        closeServiceModalBtn.addEventListener('click', closeServiceModal);
    }

    // --- Settings button ---
    const settingsBtn = document.getElementById('settingsBtn');
    if (settingsBtn) {
        settingsBtn.addEventListener('click', openSettingsModal);
    }

    // --- Close settings modal ---
    const closeSettingsModalBtn = document.getElementById('closeSettingsModalBtn');
    if (closeSettingsModalBtn) {
        closeSettingsModalBtn.addEventListener('click', closeSettingsModal);
    }

    // --- Add service button ---
    const addServiceBtn = document.getElementById('addServiceBtn');
    if (addServiceBtn) {
        addServiceBtn.addEventListener('click', () => openServiceForm());
    }

    // --- Add another link button ---
    const addLinkBtn = document.getElementById('addLinkBtn');
    if (addLinkBtn) {
        addLinkBtn.addEventListener('click', () => addLinkRow());
    }

    // --- Icon picker ---
    const toggleIconPickerBtn = document.getElementById('toggleIconPickerBtn');
    if (toggleIconPickerBtn) {
        toggleIconPickerBtn.addEventListener('click', toggleIconPicker);
    }
    const serviceIconInput = document.getElementById('serviceIcon');
    if (serviceIconInput) {
        serviceIconInput.addEventListener('input', updateIconPreview);
    }

    // --- Service form type change ---
    const serviceTypeSelect = document.getElementById('serviceType');
    if (serviceTypeSelect) {
        serviceTypeSelect.addEventListener('change', updateServiceTypeFields);
    }

    // --- Compose option change ---
    const composeOptionSelect = document.getElementById('composeOption');
    if (composeOptionSelect) {
        composeOptionSelect.addEventListener('change', updateComposeOptionFields);
    }

    // --- Compose file preview ---
    const loadComposeFileBtn = document.getElementById('loadComposeFileBtn');
    if (loadComposeFileBtn) {
        loadComposeFileBtn.addEventListener('click', loadComposePreview);
    }
    const composePathInput = document.getElementById('composePath');
    if (composePathInput) {
        // Never auto-opens the preview (stays hidden by default) — but if it's
        // already open and the path changes, refresh it instead of silently
        // showing stale content for the previous path.
        composePathInput.addEventListener('change', function () {
            const preview = document.getElementById('composeFilePreview');
            if (preview && preview.classList.contains('show')) {
                preview.classList.remove('show');
                loadComposePreview();
            }
        });
    }

    // --- Service form submit ---
    const serviceForm = document.getElementById('serviceForm');
    if (serviceForm) {
        serviceForm.addEventListener('submit', function(e) {
            e.preventDefault();
            saveService();
        });
    }

    // --- Close service form ---
    const closeServiceFormBtn = document.getElementById('closeServiceFormBtn');
    if (closeServiceFormBtn) {
        closeServiceFormBtn.addEventListener('click', closeServiceForm);
    }

    const cancelServiceFormBtn = document.getElementById('cancelServiceFormBtn');
    if (cancelServiceFormBtn) {
        cancelServiceFormBtn.addEventListener('click', closeServiceForm);
    }

    // --- Disclaimer action links ---
    document.querySelectorAll('[data-action]').forEach(el => {
        el.addEventListener('click', function(e) {
            e.preventDefault();
            const action = this.dataset.action;
            if (action === 'showDisclaimer') showDisclaimer();
            else if (action === 'closeDisclaimer') closeDisclaimer();
            else if (action === 'acceptDisclaimer') acceptDisclaimer();
        });
    });

    // --- Keyboard Escape handler ---
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            closeServiceModal();
            closeSettingsModal();
            closeServiceForm();
        }
    });

    // --- Click outside modals to close ---
    document.getElementById('serviceModal').addEventListener('click', (e) => {
        if (e.target === document.getElementById('serviceModal')) closeServiceModal();
    });
    document.getElementById('settingsModal').addEventListener('click', (e) => {
        if (e.target === document.getElementById('settingsModal')) closeSettingsModal();
    });
    document.getElementById('serviceFormModal').addEventListener('click', (e) => {
        if (e.target === document.getElementById('serviceFormModal')) closeServiceForm();
    });

});

// ==================== Initialization ====================
window.onload = function() {
    startTime();
    trackAccess();
    checkDisclaimerStatus();
};

// Weekly reset
function checkForWeeklyReset() {
    const now = new Date();
    const day = now.getUTCDay();
    const hour = now.getUTCHours();
    const isSundayMidnightCET = (day === 0 && hour >= 22) || (day === 1 && hour < 22);
    if (isSundayMidnightCET && !localStorage.getItem('resetChecked')) {
        const accepted = localStorage.getItem('disclaimerAccepted');
        localStorage.clear();
        if (accepted) localStorage.setItem('disclaimerAccepted', accepted);
        localStorage.setItem('resetChecked', 'true');
        setTimeout(() => localStorage.removeItem('resetChecked'), 3600000);
    }
}
checkForWeeklyReset();
setInterval(checkForWeeklyReset, 3600000);