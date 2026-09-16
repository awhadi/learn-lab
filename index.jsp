<%@ page contentType="text/html; charset=UTF-8" pageEncoding="UTF-8" %>
<%@ page import="java.io.*, java.nio.file.*" %>
<%
    String appVersion = "unknown";
    String pegaVersion = "unknown";
    String baseUrl = request.getScheme() + "://" + request.getServerName();
    int port = request.getServerPort();
    if (port != 80 && port != 443) baseUrl += ":" + port;
    try {
        String v = new String(Files.readAllBytes(Paths.get(application.getRealPath("/VERSION")))).trim();
        for (String ln : v.split("\n")) {
            ln = ln.trim();
            if (ln.startsWith("app:")) appVersion = ln.substring(4).trim();
            else if (ln.startsWith("pega:")) pegaVersion = ln.substring(5).trim();
        }
    } catch (Exception e) {
        // Keep the page usable, but leave a trace in catalina.out for diagnosis.
        System.err.println("[index] VERSION read failed: " + e);
    }
%><!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <script>
        // Apply the saved theme before anything paints: prevents the light-mode
        // flash when dark mode is enabled (and needs no cached script.js).
        (function () {
            try {
                var stored = localStorage.getItem('theme');
                var dark = stored ? (stored === 'dark') : window.matchMedia('(prefers-color-scheme: dark)').matches;
                document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
            } catch (e) {}
        })();
    </script>
    <title>AWHADI.ONLINE - Pega Lab</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="icon" href="/favicon.ico?" />
    <link rel="stylesheet" href="/css/fontawesome-free/css/all.min.css">
    <script src="/js/vendor/purify.min.js"></script>
    <link rel="stylesheet" href="/css/style.css?v=<%= appVersion %>">
</head>
<body>
    <div id="disclaimer">
        <div class="disclaimer-container">
            <button class="close-btn" data-action="closeDisclaimer"><i class="fas fa-times"></i></button>
            <div class="disclaimer-header"><i class="fas fa-exclamation-triangle disclaimer-icon"></i> IMPORTANT DISCLAIMER - MUST BE ACKNOWLEDGED</div>
            <div class="disclaimer-content">
                <p><strong>LEARNING ENVIRONMENT NOTICE</strong></p>
                <p>This environment is <strong>STRICTLY</strong> for learning, training, and practice purposes only.</p>
                <p><strong>COMMERCIAL USE PROHIBITED:</strong> No commercial, production, or business activities.</p>
                <p><strong>TRADEMARK ACKNOWLEDGMENT:</strong> Pega Infinity<sup>&reg;</sup>, Pega Platform<sup>&reg;</sup> are trademarks of Pegasystems Inc.</p>
                <p><strong>ENVIRONMENT RESET SCHEDULE:</strong> Every Sunday at 00:00 German Time. No data persistence guaranteed.</p>
                <button class="acknowledge-btn" data-action="acceptDisclaimer">I ACKNOWLEDGE &amp; UNDERSTAND THESE TERMS</button>
            </div>
        </div>
    </div>

    <header>
        <div class="header-inner">
            <div class="left">
                <div class="logo">
                    <a href="<%= baseUrl %>/"><img src="awhadi-online.webp" alt="awhadi.online"></a>
                    <span class="logo-version-badge" id="logoVersionBadge"><%= appVersion %></span>
                </div>
            </div>
            <div style="display:flex;align-items:center;gap:16px;">
                <span class="time-display" id="time"></span>
                <label class="theme-toggle"><span class="theme-text">Light / Dark</span><input type="checkbox" id="themeToggle"><span class="switch"></span></label>
                <div class="theme-icon-btn" id="themeIcon" title="Toggle theme">&#x1F319;</div>
                <button class="settings-btn" id="settingsBtn" title="Service Settings"><i class="fas fa-cog"></i></button>
            </div>
        </div>
    </header>

    <div id="loadingModal" class="loading-modal" style="display:none;">
        <div class="loading-modal-content">
            <div class="spinner"></div>
            <div class="loading-text" id="loadingText">Processing...</div>
        </div>
    </div>

    <div id="serviceModal" class="service-modal">
        <div class="service-modal-content">
            <div class="service-modal-header">
                <h3 id="modalServiceTitle">Manage Service</h3>
                <button class="service-modal-close" id="closeServiceModalBtn">&times;</button>
            </div>
            <div class="service-modal-body">
                <div class="service-status">
                    <span class="service-status-indicator" id="modalStatusIndicator"></span>
                    <span id="modalStatusText">Checking...</span>
                </div>
                <div class="service-buttons-modal" id="modalButtons"></div>
                <div id="modalLogsArea" style="display:none;">
                    <hr>
                    <strong><i class="fas fa-scroll"></i> Logs (last 100 lines):</strong>
                    <pre class="service-logs" id="modalLogsContent"></pre>
                </div>
            </div>
        </div>
    </div>

    <div id="settingsModal" class="settings-modal">
        <div class="settings-modal-content">
            <div class="settings-modal-header">
                <h3><i class="fas fa-cog"></i> Service Settings</h3>
                <button class="settings-modal-close" id="closeSettingsModalBtn">&times;</button>
            </div>
            <div class="settings-modal-body">
                <div class="settings-toolbar">
                    <button class="btn btn-primary" id="addServiceBtn"><i class="fas fa-plus"></i> Add Service</button>
                    <div class="settings-toolbar-right">
                        <button class="btn btn-secondary" id="resetServicesBtn" title="Restore the default service list and settings"><i class="fas fa-undo-alt"></i> Reset to default</button>
                        <a class="btn btn-secondary" id="exportSettingsLink" target="_blank" rel="noopener" href="<%= request.getContextPath() %>/service_api.jsp?action=export_settings" title="Download the current settings as a JSON file"><i class="fas fa-download"></i> Export settings</a>
                        <label class="btn btn-secondary" id="importSettingsLabel" title="Load settings from a saved JSON file">
                            <i class="fas fa-upload"></i> Import settings
                            <input type="file" id="importSettingsFile" accept=".json,application/json" style="display:none" onchange="labImportSettings(this)">
                        </label>
                    </div>
                </div>
                <div class="settings-server-note" id="settingsServerNote" style="display:none;"></div>
                <div class="services-list" id="servicesList"></div>
            </div>
        </div>
    </div>

    <div id="serviceFormModal" class="service-form-modal">
        <div class="service-form-content">
            <div class="service-form-header">
                <h3 id="serviceFormTitle">Add Service</h3>
                <button class="service-form-close" id="closeServiceFormBtn">&times;</button>
            </div>
            <div class="service-form-body">
                <form id="serviceForm">
                    <input type="hidden" id="serviceFormId" value="">
                    <div class="form-group">
                        <label for="serviceName">Service Name *</label>
                        <input type="text" id="serviceName" required placeholder="e.g., LDAP Service">
                    </div>
                    <div class="form-group">
                        <label for="serviceType">Service Type *</label>
                        <select id="serviceType" required>
                            <option value="static" selected>Static (No Management)</option>
                            <option value="docker-compose">Docker Compose</option>
                            <option value="systemctl">Systemctl Service</option>
                        </select>
                    </div>
                    <div id="dockerComposeFields">
                        <div class="form-group">
                            <label for="composeOption">Compose Source</label>
                            <select id="composeOption">
                                <option value="path">Existing Path on Server</option>
                                <option value="content">Paste Docker Compose YAML</option>
                            </select>
                        </div>
                        <div class="form-group" id="composePathGroup">
                            <label for="composePath">Compose Directory Path</label>
                            <input type="text" id="composePath" placeholder="/srv/docker-compose/my-service">
                            <button type="button" class="btn btn-secondary btn-sm" id="loadComposeFileBtn"><i class="fas fa-eye"></i> Show docker-compose.yml</button>
                            <pre class="compose-preview" id="composeFilePreview"></pre>
                        </div>
                        <div class="form-group" id="composeContentGroup" style="display:none;">
                            <label for="composeContent">Docker Compose YAML</label>
                            <textarea id="composeContent" rows="10" placeholder="version: '3.8'\nservices:\n  my-service:\n    image: nginx:latest"></textarea>
                        </div>
                    </div>
                    <div id="systemctlFields" style="display:none;">
                        <div class="form-group">
                            <label for="systemctlService">Systemctl Service Name</label>
                            <input type="text" id="systemctlService" placeholder="e.g., nginx">
                        </div>
                    </div>
                    <div class="form-group">
                        <label for="serviceIcon">Icon (FontAwesome class)</label>
                        <input type="text" id="serviceIcon" value="fas fa-cube">
                    </div>
                    <div class="form-group">
                        <label for="serviceOpenUrl">Open Link (URL)</label>
                        <input type="text" id="serviceOpenUrl" placeholder="https://server.com/path or /path">
                        <small class="form-hint">Full URL (https://...) or a path like /test or phpldapadmin — paths open on the current domain automatically.</small>
                    </div>
                    <div class="form-group">
                        <label for="serviceDescription">Description (HTML supported)</label>
                        <textarea id="serviceDescription" rows="6"></textarea>
                    </div>
                    <div class="form-group">
                        <label class="checkbox-label"><input type="checkbox" id="serviceVisible" checked> Show on main page</label>
                    </div>
                    <div class="form-group">
                        <label class="checkbox-label" id="serviceManageableLabel"><input type="checkbox" id="serviceManageable"> Enable service management</label>
                    </div>
                    <div class="form-actions">
                        <button type="button" class="btn btn-secondary" id="cancelServiceFormBtn">Cancel</button>
                        <button type="submit" class="btn btn-primary" id="saveServiceBtn">Save Service</button>
                    </div>
                </form>
            </div>
        </div>
    </div>

    <main>
        <div class="row" id="servicesContainer">
            <div class="col-md-4" style="text-align:center;padding:40px;">
                <div class="spinner"></div>
            </div>
        </div>

        <div class="row">
            <div class="col-md-4">
                <div class="card">
                    <div class="card-header"><h3 class="card-title"><i class="fas fa-user-clock"></i> Access Information</h3></div>
                    <div class="card-body">
                        <div class="access-info"><h5>Your Session Details</h5><p>First Access: <span id="displayFirstAccess">Loading...</span></p><p>Total Visits: <span id="displayAccessCount">0</span></p></div>
                        <p><small><a href="#" data-action="showDisclaimer">View Disclaimer</a></small></p>
                    </div>
                </div>
            </div>
        </div>
    </main>

    <script>
        // No client-side secret: the lab control API is open by design (see service_api.jsp).
        window.SERVICES_CONFIG = {
            baseUrl: '<%= baseUrl %>'
        };

        // Validates an uploaded settings file before it is allowed to replace the
        // server config. Returns a list of reasons; an empty list means it is safe
        // to import. The server repeats these checks (see service_api.jsp), because
        // a direct POST never goes through this page.
        function validateSettingsFile(cfg) {
            var problems = [];
            var TYPES = ['static', 'systemctl', 'docker-compose'];
            var ACTIONS = ['status', 'start', 'stop', 'restart', 'logs'];
            var unsafe = /<\s*(script|iframe|object|embed)|javascript:|data:text\/html/i;
            // Matches any "onXxx=" attribute rather than an enumerated list, so a
            // handler name this list doesn't know about (onwheel, onpointerdown,
            // oncontextmenu, ...) can't slip through.
            var handler = /\bon[a-z]{2,32}\s*=/i;

            function badUrl(u) {
                if (typeof u !== 'string' || !u.trim()) return true;
                if (/^https?:\/\//i.test(u.trim())) return false;   // explicit http(s)
                if (/^[a-z][a-z0-9+.-]*:/i.test(u.trim())) return true; // any other scheme
                return false;                                       // relative path
            }
            function plainText(v, max) {
                return typeof v === 'string' && v.trim() !== '' && v.length <= max && !/[<>]/.test(v);
            }

            if (cfg.services.length > 200) problems.push('more than 200 services');
            var seen = {};
            cfg.services.forEach(function (s, i) {
                var who = 'service ' + (i + 1) + (s && typeof s.name === 'string' && s.name ? ' ("' + s.name + '")' : '');
                if (!s || typeof s !== 'object' || Array.isArray(s)) { problems.push(who + ' is not an object'); return; }
                if (typeof s.id !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(s.id)) {
                    problems.push(who + ': id must be a lowercase slug (letters, digits, - or _)');
                } else if (seen[s.id]) {
                    problems.push(who + ': duplicate id "' + s.id + '"');
                } else {
                    seen[s.id] = true;
                }
                if (!plainText(s.name, 80)) problems.push(who + ': name must be plain text, 1-80 characters');
                if (TYPES.indexOf(s.type) === -1) problems.push(who + ': type must be static, systemctl or docker-compose');
                if (s.icon != null && !/^fa[bsr] fa-[a-z0-9-]{1,40}$/.test(String(s.icon))) problems.push(who + ': icon must look like "fas fa-cube"');
                if (s.description != null) {
                    if (typeof s.description !== 'string' || s.description.length > 20000) problems.push(who + ': description must be text under 20000 characters');
                    else if (unsafe.test(s.description) || handler.test(s.description)) problems.push(who + ': description contains script markup or an inline event handler');
                }
                if (s.type === 'systemctl' && !/^[A-Za-z0-9@._:-]{1,64}$/.test(String(s.service || ''))) {
                    problems.push(who + ': systemctl services need a valid "service" unit name');
                }
                if (s.type === 'docker-compose' && (typeof s.composePath !== 'string' || s.composePath.charAt(0) !== '/' || s.composePath.indexOf('..') !== -1)) {
                    problems.push(who + ': docker-compose services need an absolute "composePath" without ".."');
                }
                if (s.openUrl != null && badUrl(s.openUrl)) problems.push(who + ': openUrl must be an http(s) URL or a relative path');
                if (s.links != null) {
                    if (!Array.isArray(s.links) || s.links.length > 10) {
                        problems.push(who + ': links must be an array of at most 10 entries');
                    } else {
                        s.links.forEach(function (l) {
                            if (!l || typeof l !== 'object' || badUrl(l.url)) problems.push(who + ': every link needs an http(s) or relative url');
                            else if (l.text != null && !plainText(l.text, 60)) problems.push(who + ': link text must be plain text under 60 characters');
                        });
                    }
                }
                ['visible', 'manageable'].forEach(function (k) {
                    if (s[k] != null && typeof s[k] !== 'boolean') problems.push(who + ': ' + k + ' must be true or false');
                });
                if (s.actions != null) {
                    if (!Array.isArray(s.actions)) problems.push(who + ': actions must be an array');
                    else s.actions.forEach(function (a) { if (ACTIONS.indexOf(a) === -1) problems.push(who + ': unknown action "' + a + '"'); });
                }
            });

            var st = cfg.settings;
            if (st != null) {
                if (typeof st !== 'object' || Array.isArray(st)) problems.push('settings must be an object');
                else if (st.composeBasePath != null && (typeof st.composeBasePath !== 'string' || st.composeBasePath.charAt(0) !== '/' || st.composeBasePath.indexOf('..') !== -1)) {
                    problems.push('settings.composeBasePath must be an absolute path without ".."');
                }
            }
            return problems;
        }

        // Tells the truth about the deployed server file, so a stale service_api.jsp
        // cannot masquerade as a broken import. A current file answers "No
        // configuration content provided" when asked for import_services without a
        // body; an older one answers "Missing service or action". Sent as POST
        // (not GET) because the server now refuses this action on GET outright.
        window.labCheckImportSupport = function () {
            var note = document.getElementById('settingsServerNote');
            if (!note) return;
            fetch('<%= request.getContextPath() %>/service_api.jsp?action=import_services&t=' + Date.now(), { method: 'POST', cache: 'no-store' })
                .then(function (r) { return r.json(); })
                .then(function (d) {
                    var ok = !!(d && /No configuration content/i.test(d.error || ''));
                    note.style.display = ok ? 'none' : 'block';
                    if (!ok) {
                        note.innerHTML = '<i class="fas fa-exclamation-triangle"></i> '
                            + 'Import is unavailable: this server is serving an older <code>service_api.jsp</code>. '
                            + 'Copy the current <code>service_api.jsp</code> into the Tomcat webapp folder to enable import.';
                    }
                })
                .catch(function () { note.style.display = 'none'; });
        };

        // Import is handled inline (not in script.js) so it keeps working even
        // when a proxy serves a cached script.js to clients.
        function labImportSettings(input) {
            var file = input && input.files && input.files[0];
            if (!file) return;
            var reader = new FileReader();
            reader.onload = function () {
                var parsed;
                try {
                    parsed = JSON.parse(String(reader.result || ''));
                } catch (e) {
                    alert('That file is not valid JSON.');
                    input.value = '';
                    return;
                }
                if (!parsed || !Array.isArray(parsed.services)) {
                    alert('That file does not contain a service list.');
                    input.value = '';
                    return;
                }
                var problems = validateSettingsFile(parsed);
                if (problems.length) {
                    alert('That settings file was not imported:\n\n- ' + problems.slice(0, 12).join('\n- ')
                        + (problems.length > 12 ? '\n- ...and ' + (problems.length - 12) + ' more' : '')
                        + '\n\nNothing was changed.');
                    input.value = '';
                    return;
                }
                if (!confirm('Load settings from "' + file.name + '"?\n\nThis replaces the current service list. A backup of the current settings is kept on the server.')) {
                    input.value = '';
                    return;
                }
                var payload = JSON.stringify(parsed);
                var apiUrl = '<%= request.getContextPath() %>/service_api.jsp';

                // The action travels in the query string as well as the body, so the
                // server can still tell us which of the two things went wrong when it
                // answers "Missing service or action": an old file, or a dropped body.
                function postImport() {
                    var body = new URLSearchParams();
                    body.set('content', payload);
                    return fetch(apiUrl + '?action=import_services&t=' + Date.now(), {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
                        credentials: 'same-origin',
                        cache: 'no-store',
                        body: body
                    }).then(function (r) {
                        return r.json().catch(function () { return { success: false, error: 'HTTP ' + r.status }; });
                    });
                }

                // A current service_api.jsp knows import_services and answers "No
                // configuration content provided" to a body-less probe; an older one
                // falls through to "Missing service or action". Sent as POST since
                // the server now refuses this action outright on GET.
                function probeImportAction() {
                    return fetch(apiUrl + '?action=import_services&t=' + Date.now(), { method: 'POST', cache: 'no-store' })
                        .then(function (r) { return r.json(); })
                        .catch(function () { return null; });
                }

                function reportFailure(d) {
                    var msg = (d && d.error) || 'unknown error';
                    if (/No configuration content/i.test(msg)) {
                        alert('Load failed: the server received the request but no file data.\n\n'
                            + 'A proxy or filter in front of Tomcat is dropping the upload body, or the file was too large.\n'
                            + 'Your settings were NOT changed.');
                        return;
                    }
                    if (/Missing service or action/i.test(msg)) {
                        probeImportAction().then(function (p) {
                            if (p && /No configuration content/i.test(p.error || '')) {
                                alert('Load failed: this server does support the import action, but it did not receive the file data.\n\n'
                                    + 'A proxy or filter in front of Tomcat is dropping the upload body. Your settings were NOT changed.');
                            } else {
                                alert('Load failed: this server\'s service_api.jsp is out of date.\n\n'
                                    + 'Import needs the current service_api.jsp (<%= appVersion %>), which is the only file that can write the settings.\n'
                                    + 'Copy it into the Tomcat webapp, e.g.\n'
                                    + '  cp service_api.jsp /opt/tomcat/webapps/ROOT/\n'
                                    + 'then reload this page.\n\n'
                                    + 'Your settings were NOT changed.');
                            }
                        });
                        return;
                    }
                    alert('Load failed: ' + msg);
                }

                postImport()
                    .then(function (d) {
                        if (d && d.success) {
                            alert('Settings loaded.');
                            window.location.reload();
                            return;
                        }
                        reportFailure(d);
                    })
                    .catch(function (e) { alert('Load failed: ' + e.message); })
                    .finally(function () { input.value = ''; });
            };
            reader.onerror = function () {
                alert('Could not read the selected file.');
                input.value = '';
            };
            reader.readAsText(file);
        }
    </script>
    <script src="/js/script.js?v=<%= appVersion %>"></script>
</body>
</html>