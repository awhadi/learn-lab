// ==================== CONFIG (set by JSP) ====================
const API_TOKEN = window.SERVICES_CONFIG ? window.SERVICES_CONFIG.token : "K9mX2pR7vL5nB8wD4jH6fT3cY1aG0sE9qW2";
const BASE_URL = window.SERVICES_CONFIG ? window.SERVICES_CONFIG.baseUrl : "";

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

// ==================== Mobile menu ====================
function toggleMobileMenu() {
    document.getElementById('navLinks').classList.toggle('active');
}

// ==================== Time display ====================
function startTime() {
    const today = new Date();
    const timeElem = document.getElementById('time');
    if (timeElem) timeElem.innerHTML = today.toLocaleString();
    setTimeout(startTime, 500);
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

function trackAccess() {
    const now = new Date();
    let first = localStorage.getItem('firstAccess');
    if (!first) { localStorage.setItem('firstAccess', now.toISOString()); first = now.toISOString(); }
    const firstElem = document.getElementById('displayFirstAccess');
    if (firstElem) firstElem.textContent = new Date(first).toLocaleString();
    const count = (parseInt(localStorage.getItem('accessCount') || '0') + 1);
    localStorage.setItem('accessCount', count);
    const countElem = document.getElementById('displayAccessCount');
    if (countElem) countElem.textContent = count;
}

function checkDisclaimerStatus() {
    if (localStorage.getItem('disclaimerAccepted') !== 'true') {
        document.body.style.overflow = 'hidden';
        setTimeout(showDisclaimer, 500);
    }
}

// ==================== API Functions ====================
function callServiceAPI(params) {
    let url = `/service_api.jsp?token=${encodeURIComponent(API_TOKEN)}`;
    for (const [key, value] of Object.entries(params)) {
        url += `&${key}=${encodeURIComponent(value)}`;
    }
    return fetch(url, { method: params.action === 'list_services' ? 'GET' : (params.action === 'add_service' || params.action === 'update_service' || params.action === 'delete_service' ? 'POST' : (params.action === 'status' || params.action === 'logs' ? 'GET' : 'POST')) })
        .then(r => r.json());
}

// ==================== Settings Modal (Admin Panel) ====================
let currentEditingServiceId = null;

function openSettingsModal() {
    document.getElementById('settingsModal').style.display = 'flex';
    loadServicesList();
}

function closeSettingsModal() {
    document.getElementById('settingsModal').style.display = 'none';
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
    
    if (services.length === 0) {
        container.innerHTML = '<p class="empty-state">No services configured. Click "Add Service" to get started.</p>';
        return;
    }
    
    services.forEach((svc, index) => {
        const item = document.createElement('div');
        item.className = 'service-list-item';
        item.innerHTML = `
            <div class="service-list-reorder">
                <button class="reorder-btn btn-move-up" data-id="${svc.id}" title="Move up" ${index === 0 ? 'disabled' : ''}><i class="fas fa-chevron-up"></i></button>
                <button class="reorder-btn btn-move-down" data-id="${svc.id}" title="Move down" ${index === services.length - 1 ? 'disabled' : ''}><i class="fas fa-chevron-down"></i></button>
            </div>
            <div class="service-list-info">
                <div class="service-list-icon"><i class="${svc.icon || 'fas fa-cube'}"></i></div>
                <div class="service-list-details">
                    <h4>${escapeHtml(svc.name)} <span class="svc-status-badge" data-svc="${svc.id}" id="svc-status-${svc.id}">...</span></h4>
                    <p>${svc.type} ${svc.manageable ? '• Manageable' : ''}</p>
                </div>
            </div>
            <div class="service-list-actions">
                <label class="toggle-switch" title="${svc.visible ? 'Hide from main page' : 'Show on main page'}">
                    <input type="checkbox" class="visibility-toggle" data-id="${svc.id}" data-visible="${svc.visible}" ${svc.visible ? 'checked' : ''}>
                    <span class="toggle-slider"></span>
                </label>
                <button class="text-btn btn-edit" data-id="${svc.id}" title="Edit"><i class="fas fa-pencil-alt"></i> Edit</button>
                <button class="text-btn btn-delete" data-id="${svc.id}" title="Delete"><i class="fas fa-times"></i> Delete</button>
            </div>
        `;
        container.appendChild(item);
    });
    
    // Add event listeners
    container.querySelectorAll('.visibility-toggle').forEach(toggle => {
        toggle.addEventListener('change', function() {
            toggleServiceVisibility(this.dataset.id, this.dataset.visible === 'true');
        });
    });
    
    container.querySelectorAll('.btn-edit').forEach(btn => {
        btn.addEventListener('click', function() {
            editService(this.dataset.id);
        });
    });
    
    container.querySelectorAll('.btn-delete').forEach(btn => {
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
    
    // Fetch all statuses in one batch call
    const manageableIds = services.filter(s => s.manageable).map(s => s.id);
    services.forEach(svc => {
        if (!svc.manageable) {
            const badge = document.getElementById('svc-status-' + svc.id);
            if (badge) badge.textContent = '—';
        }
    });
    if (manageableIds.length > 0) {
        fetchAllStatuses();
    }
}

function fetchAllStatuses() {
    callServiceAPI({ action: 'batch_status' })
        .then(data => {
            if (!data.success || !data.statuses) return;
            for (const [id, status] of Object.entries(data.statuses)) {
                const badge = document.getElementById('svc-status-' + id);
                if (!badge) continue;
                if (status === 'running') {
                    badge.textContent = 'running';
                    badge.className = 'svc-status-badge status-running';
                } else if (status === 'stopped') {
                    badge.textContent = 'stopped';
                    badge.className = 'svc-status-badge status-stopped';
                } else if (status === 'static' || status === 'not-manageable') {
                    badge.textContent = '—';
                    badge.className = 'svc-status-badge status-unknown';
                } else {
                    badge.textContent = 'unknown';
                    badge.className = 'svc-status-badge status-unknown';
                }
            }
        })
        .catch(() => {
            services.forEach(svc => {
                const badge = document.getElementById('svc-status-' + svc.id);
                if (badge) { badge.textContent = 'unknown'; badge.className = 'svc-status-badge status-unknown'; }
            });
        });
}

function reorderService(id, dir) {
    callServiceAPI({ action: 'reorder_service', id: id, dir: dir })
        .then(data => {
            if (data.success) {
                loadServicesList();
            } else {
                alert('Failed to reorder: ' + (data.error || 'Unknown'));
            }
        })
        .catch(err => {
            alert('Error reordering: ' + err.message);
        });
}

function toggleServiceVisibility(id, currentVisible) {
    if (currentVisible) {
        const confirmed = confirm('Hide this service?\n\nWould you also like to stop the running service?\n\nClick OK to STOP and HIDE, or Cancel to just HIDE.');
        if (confirmed) {
            callServiceAPI({ service: id, action: 'status' })
                .then(statusData => {
                    if (statusData.success && statusData.status === 'running') {
                        callServiceAPI({ service: id, action: 'stop' })
                            .then(() => {
                                callServiceAPI({ action: 'toggle_visible', id: id })
                                    .then(data => {
                                        if (data.success) loadServicesList();
                                        else alert('Failed: ' + (data.error || 'Unknown'));
                                    });
                            })
                            .catch(() => {
                                callServiceAPI({ action: 'toggle_visible', id: id })
                                    .then(data => { if (data.success) loadServicesList(); });
                            });
                    } else {
                        callServiceAPI({ action: 'toggle_visible', id: id })
                            .then(data => {
                                if (data.success) loadServicesList();
                                else alert('Failed: ' + (data.error || 'Unknown'));
                            });
                    }
                })
                .catch(() => {
                    callServiceAPI({ action: 'toggle_visible', id: id })
                        .then(data => { if (data.success) loadServicesList(); });
                });
        } else {
            callServiceAPI({ action: 'toggle_visible', id: id })
                .then(data => {
                    if (data.success) loadServicesList();
                    else alert('Failed: ' + (data.error || 'Unknown'));
                })
                .catch(err => alert('Error: ' + err.message));
        }
    } else {
        callServiceAPI({ action: 'toggle_visible', id: id })
            .then(data => {
                if (data.success) loadServicesList();
                else alert('Failed: ' + (data.error || 'Unknown'));
            })
            .catch(err => alert('Error: ' + err.message));
    }
}

// ==================== Add/Edit Service ====================
function openServiceForm(serviceId = null) {
    currentEditingServiceId = serviceId;
    const modal = document.getElementById('serviceFormModal');
    const title = document.getElementById('serviceFormTitle');
    const form = document.getElementById('serviceForm');
    
    form.reset();
    document.getElementById('serviceFormId').value = '';
    document.getElementById('serviceVisible').checked = true;
    document.getElementById('serviceManageable').checked = true;
    document.getElementById('serviceIcon').value = 'fas fa-cube';
    
    if (serviceId) {
        title.textContent = 'Edit Service';
        loadServiceForEdit(serviceId);
        document.getElementById('serviceType').disabled = true;
    } else {
        title.textContent = 'Add Service';
        document.getElementById('serviceType').disabled = false;
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
                    document.getElementById('serviceOpenUrl').value = (service.openUrl || (service.links && service.links.length > 0 ? service.links[0].url : '')) || '';
                    document.getElementById('serviceDescription').value = service.description || '';
                    document.getElementById('serviceVisible').checked = service.visible;
                    document.getElementById('serviceManageable').checked = service.manageable;
                    
                    if (service.type === 'docker-compose') {
                        document.getElementById('composePath').value = service.composePath || '';
                        document.getElementById('composeOption').value = 'path';
                        updateComposeOptionFields();
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
}

function updateComposeOptionFields() {
    const option = document.getElementById('composeOption').value;
    document.getElementById('composePathGroup').style.display = option === 'path' ? 'block' : 'none';
    document.getElementById('composeContentGroup').style.display = option === 'content' ? 'block' : 'none';
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
    const openUrl = document.getElementById('serviceOpenUrl').value.trim();
    
    const params = {
        action: id ? 'update_service' : 'add_service',
        name: name,
        type: type,
        icon: icon,
        description: description,
        visible: visible,
        manageable: manageable,
        openUrl: openUrl
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
                refreshMainPage();
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
    if (!confirm('Are you sure you want to delete this service? This will stop the service and remove all files.')) {
        return;
    }
    
    callServiceAPI({ action: 'delete_service', id: id })
        .then(data => {
            if (data.success) {
                loadServicesList();
                refreshMainPage();
            } else {
                alert('Failed to delete service: ' + (data.error || 'Unknown error'));
            }
        })
        .catch(err => {
            alert('Error: ' + err.message);
        });
}

function refreshMainPage() {
    // Reload the page to refresh the service cards
    window.location.reload();
}

// ==================== Service Management Modal ====================
let currentService = null;

function openServiceModal(service) {
    currentService = service;
    const modal = document.getElementById('serviceModal');
    const titleElem = document.getElementById('modalServiceTitle');
    titleElem.innerText = service.charAt(0).toUpperCase() + service.slice(1) + ' Management';
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
        const stopBtn = document.createElement('button');
        stopBtn.className = 'btn-stop';
        stopBtn.innerHTML = '<i class="fas fa-stop"></i> Stop';
        stopBtn.onclick = () => performAction(service, 'stop');
        const restartBtn = document.createElement('button');
        restartBtn.className = 'btn-restart';
        restartBtn.innerHTML = '<i class="fas fa-sync-alt"></i> Restart';
        restartBtn.onclick = () => performAction(service, 'restart');
        container.appendChild(stopBtn);
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
}

function performAction(service, action) {
    if (!confirm(`Are you sure you want to ${action} ${service}?`)) return;
    executeAction(service, action);
}

function executeAction(service, action) {
    const loadingModal = document.getElementById('loadingModal');
    const loadingText = document.getElementById('loadingText');
    loadingText.innerText = `${action}ing ${service}...`;
    loadingModal.style.display = 'flex';

    callServiceAPI({ service: service, action: action })
        .then(data => {
            loadingModal.style.display = 'none';
            if (data.success) {
                alert(`${service} ${action} completed successfully.`);
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

// ==================== Legacy restart for logo menu ====================
let currentRestartType = null;

function confirmRestart(service) {
    currentRestartType = service;
    const nameElem = document.getElementById('restartServiceName');
    if (nameElem) {
        if (service === 'tomcat') {
            nameElem.textContent = 'Tomcat Server';
        } else if (service === 'docker') {
            nameElem.textContent = 'Docker Service';
        } else {
            nameElem.textContent = service;
        }
    }
    document.getElementById('restartConfirmModal').style.display = 'flex';
}

function closeRestartModal() {
    document.getElementById('restartConfirmModal').style.display = 'none';
    currentRestartType = null;
}

function executeRestart(service) {
    const loadingModal = document.getElementById('loadingModal');
    const loadingText = document.getElementById('loadingText');
    loadingText.innerText = `Restarting ${service}...`;
    loadingModal.style.display = 'flex';

    callServiceAPI({ service: service, action: 'restart' })
        .then(data => {
            loadingModal.style.display = 'none';
            if (data.success) {
                alert(`${service} restarted successfully.`);
            } else {
                alert(`Error restarting ${service}: ${data.error}`);
            }
        })
        .catch(err => {
            loadingModal.style.display = 'none';
            alert(`Failed to restart ${service}: ${err.message}`);
        });
}

// ==================== Helper Functions ====================
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function resolveOpenUrl(url) {
    if (!url) return '#';
    if (/^https?:\/\//i.test(url)) return url;
    if (url.startsWith('/')) return url;
    if (url === '' || url === '.') return '/';
    return '/' + url;
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
                let openHref = null;
                let openText = '';
                if (typeof svc.openUrl === 'string' && svc.openUrl.trim() !== '') {
                    openHref = resolveOpenUrl(svc.openUrl.trim());
                    openText = `Open ${svc.name}`;
                } else if (svc.links && svc.links.length > 0) {
                    const link = svc.links[0];
                    openHref = resolveOpenUrl(link.url);
                    openText = link.text || `Open ${svc.name}`;
                }
                const hasOpen = !!openHref;

                const footerHtml = (canManage || hasOpen)
                    ? `<div class="card-footer-right">
                        <div class="card-footer-links">${hasOpen ? `<a href="${openHref}" target="_blank" class="card-link-sm"><i class="fas fa-external-link-alt"></i> ${escapeHtml(openText)}</a>` : ''}</div>
                        ${canManage ? `<a href="#" class="manage-btn" data-service="${svc.id}"><i class="fas fa-cog"></i> Manage</a>` : ''}
                       </div>`
                    : '';

                card.innerHTML = `
                    <div class="card">
                        <div class="card-header">
                            <h3 class="card-title"><i class="${escapeHtml(svc.icon || 'fas fa-cube')}"></i> ${escapeHtml(svc.name)}</h3>
                        </div>
                        <div class="card-body">
                            <div class="card-service-info">${svc.description || ''}</div>
                        </div>
                        ${footerHtml}
                    </div>
                `;
                container.appendChild(card);
            });

            container.querySelectorAll('.manage-btn').forEach(btn => {
                btn.addEventListener('click', function(e) {
                    e.preventDefault();
                    openServiceModal(this.dataset.service);
                });
            });
        })
        .catch(err => {
            container.innerHTML = `<div class="col-md-4"><div class="card"><div class="card-body"><p>Error loading services: ${escapeHtml(err.message)}</p></div></div></div>`;
        });
}

// ==================== Initialization ====================
document.addEventListener('DOMContentLoaded', function() {
    
    // --- Logo dropdown ---
    const logoBtn = document.getElementById('logoMenuBtn');
    const dropdown = document.getElementById('logoDropdown');
    const versionBadge = document.getElementById('logoVersionBadge');
    if (logoBtn && dropdown) {
        if (versionBadge) {
            versionBadge.addEventListener('click', (e) => {
                e.stopPropagation();
                e.preventDefault();
                dropdown.classList.toggle('show');
            });
        }
        document.addEventListener('click', (e) => {
            if (!logoBtn.contains(e.target)) dropdown.classList.remove('show');
        });
    }

    // --- Mobile menu button ---
    const mobileBtn = document.querySelector('.mobile-menu-btn');
    if (mobileBtn) mobileBtn.addEventListener('click', toggleMobileMenu);

    // --- Load service cards dynamically ---
    loadAndRenderServices();

    // --- RESTART LINKS in logo dropdown ---
    document.querySelectorAll('.restart-link').forEach(link => {
        link.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            const service = this.dataset.restart;
            if (service) confirmRestart(service);
        });
    });

    // --- Legacy restart confirm button ---
    const confirmRestartBtn = document.getElementById('confirmRestartBtn');
    if (confirmRestartBtn) {
        confirmRestartBtn.addEventListener('click', function() {
            if (currentRestartType) {
                const service = currentRestartType;
                closeRestartModal();
                executeRestart(service);
            }
        });
    }

    // --- Legacy restart cancel button ---
    const cancelRestartBtn = document.getElementById('cancelRestartBtn');
    if (cancelRestartBtn) {
        cancelRestartBtn.addEventListener('click', closeRestartModal);
    }

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
            closeRestartModal();
            closeServiceModal();
            closeSettingsModal();
            closeServiceForm();
        }
    });

    // --- Click outside modals to close ---
    document.getElementById('restartConfirmModal').addEventListener('click', (e) => {
        if (e.target === document.getElementById('restartConfirmModal')) closeRestartModal();
    });
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