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
    } catch (Exception e) {}
%><!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>AWHADI.ONLINE - Pega Lab</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="icon" href="/favicon.ico?" />
    <link rel="stylesheet" href="/css/fontawesome-free/css/all.min.css">
    <script src="/js/vendor/purify.min.js"></script>
    <link rel="stylesheet" href="/css/style.css">
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
                <div class="logo" id="logoMenuBtn">
                    <a href="<%= baseUrl %>/"><img src="awhadi-online.webp" alt="awhadi.online"></a>
                    <span class="logo-version-badge" id="logoVersionBadge"><%= appVersion %></span>
                </div>
                <button class="mobile-menu-btn" style="display:none;"><i class="fas fa-bars"></i></button>
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
                </div>
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
    </script>
    <script src="/js/script.js"></script>
</body>
</html>