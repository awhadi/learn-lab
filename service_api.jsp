<%@ page import="java.io.*, java.nio.charset.StandardCharsets, java.nio.file.*, java.util.*, java.util.concurrent.*" %>
<%@ page contentType="application/json; charset=UTF-8" %><%!
    // Serializes config read-modify-write cycles across concurrent requests.
    static final Object CONFIG_LOCK = new Object();
    static final int MAX_LOG_LINES = 2000;

    // Central error logger: everything written here lands in catalina.out
    // (Tomcat routes stderr there) with a timestamp, a short context and a
    // stack trace when one is available.
    private void logProblem(String where, Throwable t) {
        java.text.SimpleDateFormat fmt = new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
        String detail = (t == null) ? "" : (" :: " + t.getClass().getName() + ": " + t.getMessage());
        System.err.println("[service-api] " + fmt.format(new java.util.Date()) + " " + where + detail);
        if (t != null) t.printStackTrace();
    }

    private String readConfigFile(String path) {
        try {
            return new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8);
        } catch (Exception e) {
            logProblem("readConfigFile failed for " + path, e);
            return "{\"services\":[],\"settings\":{\"composeBasePath\":\"/srv/docker-compose\"}}";
        }
    }

    private void writeConfigFile(String path, String content) throws Exception {
        // Atomic write: never leave a half-written config behind.
        Path target = Paths.get(path);
        Path tmp = target.resolveSibling(target.getFileName().toString() + ".tmp");
        Files.write(tmp, content.getBytes(StandardCharsets.UTF_8));
        try {
            Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (java.nio.file.AtomicMoveNotSupportedException amnse) {
            Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    // Canonicalize a filesystem path, resolving symlinks when possible.
    private String normalizePath(String p) {
        if (p == null) return "";
        try { return Paths.get(p).toRealPath().toString(); }
        catch (Exception e) { try { return Paths.get(p).toAbsolutePath().normalize().toString(); } catch (Exception e2) { return p; } }
    }

    private boolean isWithinBase(String path, String base) {
        if (path == null || base == null || base.isEmpty()) return false;
        String p = normalizePath(path);
        String b = normalizePath(base);
        if (!p.startsWith(b)) return false;
        return p.length() == b.length() || p.charAt(b.length()) == '/';
    }

    // Runs a command with a hard timeout and bounded output capture.
    private String runProcess(ProcessBuilder pb, long timeoutSeconds, int maxOutputLines) throws Exception {
        Process proc = pb.start();
        StringBuilder output = new StringBuilder();
        int read = 0;
        long deadline = System.currentTimeMillis() + timeoutSeconds * 1000L;
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(proc.getInputStream(), StandardCharsets.UTF_8))) {
            while (System.currentTimeMillis() < deadline) {
                if (proc.waitFor(200, TimeUnit.MILLISECONDS)) break;
                while (read < maxOutputLines && reader.ready()) {
                    String ln = reader.readLine();
                    if (ln == null) break;
                    output.append(ln).append("\n");
                    read++;
                }
            }
            boolean timedOut = proc.isAlive();
            if (timedOut) {
                logProblem("command timed out after " + timeoutSeconds + "s: " + pb.command(), null);
                proc.destroyForcibly();
                proc.waitFor();
                if (read < maxOutputLines) output.append("(command timed out after ").append(timeoutSeconds).append("s)\n");
            }
            while (read < maxOutputLines) {
                String ln = reader.readLine();
                if (ln == null) break;
                output.append(ln).append("\n");
                read++;
            }
        }
        return output.toString();
    }

    // Single shared status probe used by BOTH the Manage modal (per-service
    // action) and Settings batch_status, so they always agree. It runs the
    // exact same sudo WEB-INF/service_control.sh wrapper as start/stop/restart/logs
    // (which already has passwordless sudo on the lab), with a bounded
    // subprocess and a small output cap.
    // Candidate control-script locations: the new WEB-INF home first, then the
    // legacy web-root path. Whichever exists (and is permitted by sudoers) works.
    private String[] controlScriptCandidates() {
        return new String[]{
            "/opt/tomcat/webapps/ROOT/WEB-INF/service_control.sh",
            "/opt/tomcat/webapps/ROOT/service_control.sh"
        };
    }

    private boolean anyControlScriptExists() {
        for (String s : controlScriptCandidates()) if (new java.io.File(s).isFile()) return true;
        return false;
    }

    // True when the output looks like the command never really ran (sudo denied
    // it, asked for a password, the path is wrong, ...).
    private boolean isScriptError(String out) {
        String low = out == null ? "" : out.toLowerCase();
        return low.contains("sudo:") || low.contains("command not found")
            || low.contains("no such file") || low.contains("not found")
            || low.contains("permission denied") || low.contains("is not allowed")
            || low.contains("a password is required") || low.contains("incorrect password")
            || low.contains("a terminal is required") || low.contains("not allowed to execute");
    }

    // Runs the control script, trying every existing candidate path until one is
    // actually permitted. This covers a sudoers rule that still points at the
    // legacy path while the script now lives in WEB-INF (and vice versa).
    private String runControlScript(long timeoutSeconds, int maxOutputLines, java.util.List<String> triedPaths, String... args) {
        String lastError = "";
        for (String script : controlScriptCandidates()) {
            if (!new java.io.File(script).isFile()) continue;
            triedPaths.add(script);
            try {
                String[] cmd = new String[args.length + 2];
                cmd[0] = "sudo";
                cmd[1] = script;
                System.arraycopy(args, 0, cmd, 2, args.length);
                ProcessBuilder pb = new ProcessBuilder(cmd);
                pb.redirectErrorStream(true);
                String out = runProcess(pb, timeoutSeconds, maxOutputLines).trim();
                if (!isScriptError(out)) return out;
                lastError = out;
                logProblem("control script " + script + " not usable, trying next: " + out, null);
            } catch (Exception ex) {
                logProblem("control script " + script + " threw", ex);
                lastError = String.valueOf(ex.getMessage());
            }
        }
        return lastError;
    }

    private String probeStatus(String type, String serviceId, String systemctlService, String composePath) {
        try {
            if (!anyControlScriptExists()) {
                logProblem("probeStatus: no control script found in " + java.util.Arrays.toString(controlScriptCandidates()), null);
                return "unknown";
            }
            if ("systemctl".equals(type)) {
                if (systemctlService == null || systemctlService.isEmpty()) return "unknown";
                String out = runControlScript(10, 200, new java.util.ArrayList<String>(),
                    "systemctl", systemctlService, "status", "100");
                if (out.equals("active") || out.equals("running")) return "running";
                if (out.equals("inactive") || out.equals("dead") || out.equals("stopped") || out.isEmpty()) return "stopped";
                logProblem("probeStatus systemctl=" + systemctlService + " unexpected output: " + out, null);
                return "unknown";
            }
            if ("docker-compose".equals(type)) {
                if (composePath == null || composePath.isEmpty()) return "stopped";
                // Cheap guard: nothing can be running from a directory that is absent.
                java.io.File d = new java.io.File(composePath);
                if (!d.isDirectory()) return "stopped";
                String out = runControlScript(10, 200, new java.util.ArrayList<String>(),
                    "docker-compose", (serviceId != null ? serviceId : "compose"), "status", "100", composePath);
                if (out.equals("running")) return "running";
                if (out.equals("stopped") || out.isEmpty()) return "stopped";
                logProblem("probeStatus compose=" + composePath + " unexpected output: " + out, null);
                return "unknown";
            }
            return "static";
        } catch (Exception ex) {
            logProblem("probeStatus(" + type + ", " + serviceId + ") failed", ex);
            return "unknown";
        }
    }

    private String escapeJsonStr(String s) {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder();
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int)c));
                    else sb.append(c);
            }
        }
        return sb.toString();
    }

    // Validates an uploaded settings file before it replaces the live config.
    // Returns null when the content is a settings file we are willing to serve,
    // or a human-readable reason when it is not. Checks run on a whitespace-free
    // copy, so formatting differences cannot hide anything; JSON escapes its own
    // quotes, so a description mentioning "type":"x" cannot be mistaken for a
    // real field.
    private String validateSettingsImport(String content) {
        String flat = content.replaceAll("\\s+", "");
        String lower = flat.toLowerCase();
        if (flat.length() > 1048576) return "Configuration too large (1 MB limit)";
        for (String bad : new String[]{"<script", "<iframe", "<object", "<embed", "javascript:", "data:text/html", "srcdoc"}) {
            if (lower.contains(bad)) return "Refused: the file contains " + bad + "";
        }
        java.util.regex.Matcher handler = java.util.regex.Pattern.compile(
            "\\bon(click|dblclick|load|error|mouse[a-z]*|key[a-z]*|focus|blur|submit|change|input|toggle|animation[a-z]*|transition[a-z]*)\\s*=").matcher(content);
        if (handler.find()) return "Refused: the file contains an inline event handler (" + handler.group() + ")";

        java.util.regex.Pattern idRe = java.util.regex.Pattern.compile("\\\"id\\\":\\\"([^\\\"]*)\\\"");
        java.util.regex.Pattern typeRe = java.util.regex.Pattern.compile("\\\"type\\\":\\\"([^\\\"]*)\\\"");
        Set<String> ids = new HashSet<String>();
        int count = 0;
        java.util.regex.Matcher m = idRe.matcher(flat);
        while (m.find()) {
            String id = m.group(1);
            count++;
            if (count > 200) return "Refused: more than 200 services";
            if (!id.matches("[a-z0-9][a-z0-9_-]{0,63}")) return "Refused: unsafe service id \"" + id + "\"";
            if (!ids.add(id)) return "Refused: duplicate service id \"" + id + "\"";
        }
        if (count == 0) return "Refused: no services found in the file";
        m = typeRe.matcher(flat);
        while (m.find()) {
            String t = m.group(1);
            if (!t.equals("static") && !t.equals("systemctl") && !t.equals("docker-compose")) {
                return "Refused: unknown service type \"" + t + "\"";
            }
        }
        java.util.regex.Matcher base = java.util.regex.Pattern.compile(
            "\\\"composeBasePath\\\":\\\"([^\\\"]*)\\\"").matcher(flat);
        while (base.find()) {
            String p = base.group(1);
            if (!p.startsWith("/") || p.contains("..")) return "Refused: composeBasePath must be an absolute path without \"..\"";
        }
        return null;
    }

    private String makeId(String name) {
        String id = name.toLowerCase().replaceAll("[^a-z0-9]+", "-").replaceAll("^-|-$", "");
        return id + "-" + System.currentTimeMillis();
    }

    private int findMatchingBrace(String json, int start) {
        if (start < 0 || start >= json.length() || json.charAt(start) != '{') return -1;
        int depth = 0;
        boolean inString = false;
        boolean escaped = false;
        for (int i = start; i < json.length(); i++) {
            char c = json.charAt(i);
            if (escaped) { escaped = false; continue; }
            if (c == '\\') { escaped = true; continue; }
            if (c == '"') { inString = !inString; continue; }
            if (inString) continue;
            if (c == '{') depth++;
            else if (c == '}') { depth--; if (depth == 0) return i; }
        }
        return -1;
    }

    private int findJsonStringEnd(String json, int start) {
        int i = start + 1;
        while (i < json.length()) {
            char c = json.charAt(i);
            if (c == '\\') { i += 2; continue; }
            if (c == '"') return i;
            i++;
        }
        return -1;
    }

    private String extractJsonField(String json, String field) {
        String pattern = "\"" + field + "\"";
        int idx = json.indexOf(pattern);
        if (idx == -1) return null;
        int colonIdx = json.indexOf(":", idx + pattern.length());
        if (colonIdx == -1) return null;
        int quoteStart = -1;
        for (int i = colonIdx + 1; i < json.length(); i++) {
            char c = json.charAt(i);
            if (c == '"') { quoteStart = i; break; }
            if (c != ' ' && c != '\t' && c != '\n') return null;
        }
        if (quoteStart == -1) return null;
        int quoteEnd = findJsonStringEnd(json, quoteStart);
        if (quoteEnd == -1) return null;
        return json.substring(quoteStart + 1, quoteEnd);
    }

    private int findServiceObjStart(String json, String id) {
        int idx = json.indexOf("\"id\":\"" + id + "\"");
        if (idx == -1) idx = json.indexOf("\"id\": \"" + id + "\"");
        if (idx == -1) idx = json.indexOf("\"id\" : \"" + id + "\"");
        if (idx == -1) return -1;
        return json.lastIndexOf("{", idx);
    }

    private int findArrayStart(String json) {
        int idx = json.indexOf("\"services\"");
        if (idx == -1) return -1;
        int bracket = json.indexOf("[", idx);
        return bracket;
    }

    private int findArrayEnd(String json, int arrStart) {
        int depth = 0;
        boolean inString = false;
        boolean esc = false;
        for (int i = arrStart; i < json.length(); i++) {
            char c = json.charAt(i);
            if (esc) { esc = false; continue; }
            if (c == '\\') { esc = true; continue; }
            if (c == '"') { inString = !inString; continue; }
            if (inString) continue;
            if (c == '[') depth++;
            else if (c == ']') { depth--; if (depth == 0) return i; }
        }
        return -1;
    }

    private String[] splitTopLevel(String json, int arrStart, int arrEnd) {
        java.util.List<String> list = new java.util.ArrayList<String>();
        int i = arrStart + 1;
        while (i < arrEnd) {
            if (json.charAt(i) == '{') {
                int end = findMatchingBrace(json, i);
                if (end == -1 || end > arrEnd) return null;
                list.add(json.substring(i, end + 1));
                i = end + 1;
            } else {
                i++;
            }
        }
        return list.toArray(new String[list.size()]);
    }

    private String extractIdSpaced(String block) {
        String[] patterns = {"\"id\":\"", "\"id\": \"", "\"id\" : \""};
        for (String p : patterns) {
            int si = block.indexOf(p);
            if (si == -1) continue;
            int qs = si + p.length();
            int qe = block.indexOf("\"", qs);
            if (qe == -1) continue;
            return block.substring(qs, qe);
        }
        return "";
    }

    private String updateJsonField(String json, String field, String value) {
        String pattern = "\"" + field + "\"";
        int idx = json.indexOf(pattern);
        String escaped = escapeJsonStr(value);
        if (idx == -1) {
            // Field does not exist: add it just before the closing brace.
            int close = json.length() - 1;
            while (close >= 0 && (json.charAt(close) == ' ' || json.charAt(close) == '\t' || json.charAt(close) == '\n' || json.charAt(close) == '\r')) close--;
            if (close < 0 || json.charAt(close) != '}') return json;
            String prefix = json.substring(0, close).trim();
            String insert = "\"" + field + "\":\"" + escaped + "\"";
            if (prefix.endsWith("{") || prefix.endsWith(",")) {
                return json.substring(0, close) + insert + json.substring(close);
            }
            return json.substring(0, close) + "," + insert + json.substring(close);
        }
        int colonIdx = json.indexOf(":", idx + pattern.length());
        if (colonIdx == -1) return json;
        int quoteStart = -1;
        for (int i = colonIdx + 1; i < json.length(); i++) {
            char c = json.charAt(i);
            if (c == '"') { quoteStart = i; break; }
            if (c != ' ' && c != '\t' && c != '\n') return json;
        }
        if (quoteStart == -1) return json;
        int quoteEnd = findJsonStringEnd(json, quoteStart);
        if (quoteEnd == -1) return json;
        return json.substring(0, quoteStart + 1) + escaped + json.substring(quoteEnd);
    }
    private String removeJsonField(String json, String field) {
        String pattern = "\"" + field + "\"";
        int keyStart = json.indexOf(pattern);
        if (keyStart == -1) return json;
        int colonIdx = json.indexOf(":", keyStart + pattern.length());
        if (colonIdx == -1) return json;

        // Locate the end of the field's value (string, number, boolean, array or object).
        int valueEnd = colonIdx + 1;
        int depth = 0;
        boolean inString = false;
        boolean escaped = false;
        while (valueEnd < json.length()) {
            char c = json.charAt(valueEnd);
            if (inString) {
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') inString = false;
            } else {
                if (c == '"') inString = true;
                else if (c == '[' || c == '{') depth++;
                else if (c == ']' || c == '}') {
                    depth--;
                    if (depth < 0) break;
                } else if (c == ',' && depth == 0) {
                    break;
                }
            }
            valueEnd++;
        }

        // Remove the field key and value.
        String result = json.substring(0, keyStart) + json.substring(valueEnd);

        // Remove exactly one adjacent comma so the remaining JSON stays valid.
        int fwd = keyStart;
        while (fwd < result.length() && (result.charAt(fwd) == ' ' || result.charAt(fwd) == '\t' || result.charAt(fwd) == '\n' || result.charAt(fwd) == '\r')) fwd++;
        if (fwd < result.length() && result.charAt(fwd) == ',') {
            return result.substring(0, keyStart) + result.substring(fwd + 1);
        }
        int bwd = keyStart;
        while (bwd > 0 && (result.charAt(bwd - 1) == ' ' || result.charAt(bwd - 1) == '\t' || result.charAt(bwd - 1) == '\n' || result.charAt(bwd - 1) == '\r')) bwd--;
        if (bwd > 0 && result.charAt(bwd - 1) == ',') {
            return result.substring(0, bwd - 1) + result.substring(keyStart);
        }
        return result;
    }
%><%
    // NOTE: Open by design (self-hosted learning lab). No secret is checked here;
    // if this dashboard is ever exposed beyond the lab, protect /service_api.jsp at
    // the reverse proxy or add real authentication before enabling control actions.
    String configPath = application.getRealPath("/WEB-INF/services.json");
    String service = request.getParameter("service");
    String action = request.getParameter("action");
    String linesParam = request.getParameter("lines");
    int lines = 100;
    if (linesParam != null && !linesParam.isEmpty()) {
        try {
            lines = Integer.parseInt(linesParam);
        } catch (NumberFormatException nfe) {
            out.print("{\"success\":false,\"error\":\"Invalid 'lines' parameter\"}");
            return;
        }
        if (lines < 1) lines = 1;
        if (lines > MAX_LOG_LINES) lines = MAX_LOG_LINES;
    }

    if (action != null && (action.equals("list_services") || action.equals("add_service") ||
        action.equals("update_service") || action.equals("delete_service") || action.equals("toggle_visible") ||
        action.equals("reorder_service") || action.equals("batch_status") || action.equals("reset_services")
        || action.equals("read_compose_file") || action.equals("import_services") || action.equals("export_settings"))) {

        try {
            String jsonConfig = readConfigFile(configPath);

            if ("export_settings".equals(action)) {
                // Plain file download: works without any client-side JavaScript,
                // so a proxy-cached script.js cannot break it.
                String exportStamp = new java.text.SimpleDateFormat("yyyyMMdd-HHmmss").format(new java.util.Date());
                response.setContentType("application/json; charset=UTF-8");
                response.setHeader("Content-Disposition", "attachment; filename=\"lab-services-" + exportStamp + ".json\"");
                out.print(readConfigFile(configPath));
                return;
            }

            if ("reset_services".equals(action)) {
                // Restore the shipped default config snapshot (see WEB-INF/services.default.json).
                synchronized (CONFIG_LOCK) {
                    Path df = Paths.get(application.getRealPath("/WEB-INF/services.default.json"));
                    if (!Files.exists(df)) {
                        logProblem("reset_services: default snapshot missing at " + df, null);
                        out.print("{\"success\":false,\"error\":\"Default configuration file is missing on the server\"}");
                        return;
                    }
                    String defaultCfg = new String(Files.readAllBytes(df), StandardCharsets.UTF_8);
                    writeConfigFile(configPath, defaultCfg);
                }
                out.print("{\"success\":true,\"message\":\"Services reset to defaults\"}");
                return;
            }

            if ("import_services".equals(action)) {
                // Restore a settings file previously saved with "Save settings".
                String content = request.getParameter("content");
                if (content == null || content.trim().isEmpty()) {
                    out.print("{\"success\":false,\"error\":\"No configuration content provided\"}");
                    return;
                }
                if (content.length() > 1048576) {
                    out.print("{\"success\":false,\"error\":\"Configuration too large (1 MB limit)\"}");
                    return;
                }
                int impArrStart = findArrayStart(content);
                if (impArrStart == -1 || findArrayEnd(content, impArrStart) == -1) {
                    logProblem("import_services: rejected content without a services array", null);
                    out.print("{\"success\":false,\"error\":\"Invalid settings file: no 'services' array found\"}");
                    return;
                }
                // The file replaces the live config, so refuse anything unsafe or
                // malformed instead of writing it (the browser validates too, this
                // is the check that cannot be bypassed by posting directly).
                String importProblem = validateSettingsImport(content);
                if (importProblem != null) {
                    logProblem("import_services: rejected file: " + importProblem, null);
                    out.print("{\"success\":false,\"error\":\"" + escapeJsonStr(importProblem) + "\"}");
                    return;
                }
                synchronized (CONFIG_LOCK) {
                    try {
                        String stamp = new java.text.SimpleDateFormat("yyyyMMdd-HHmmss").format(new java.util.Date());
                        Path bak = Paths.get(application.getRealPath("/WEB-INF"), "services.backup-" + stamp + ".json");
                        Files.write(bak, readConfigFile(configPath).getBytes(StandardCharsets.UTF_8));
                        logProblem("import_services: previous settings backed up to " + bak, null);
                        java.io.File dir = new java.io.File(application.getRealPath("/WEB-INF"));
                        java.io.File[] baks = dir.listFiles(new java.io.FilenameFilter() {
                            public boolean accept(java.io.File d, String n) { return n.startsWith("services.backup-"); }
                        });
                        if (baks != null && baks.length > 10) {
                            java.util.Arrays.sort(baks, new java.util.Comparator<java.io.File>() {
                                public int compare(java.io.File a, java.io.File b) { return Long.compare(a.lastModified(), b.lastModified()); }
                            });
                            for (int i = 0; i < baks.length - 10; i++) baks[i].delete();
                        }
                    } catch (Exception be) {
                        logProblem("import_services: backup failed (continuing)", be);
                    }
                    writeConfigFile(configPath, content);
                }
                out.print("{\"success\":true,\"message\":\"Settings imported\"}");
                return;
            }

            if ("read_compose_file".equals(action)) {
                // Read-only preview of the compose file for a chosen directory,
                // so users can verify what they are attaching to (path source).
                String cp = request.getParameter("composePath");
                if (cp == null || cp.trim().isEmpty()) {
                    logProblem("read_compose_file: missing composePath parameter", null);
                    out.print("{\"success\":false,\"error\":\"Compose path is required\"}");
                    return;
                }
                String baseP = extractJsonField(jsonConfig, "composeBasePath");
                if (baseP == null || baseP.isEmpty()) baseP = "/srv/docker-compose";
                if (!isWithinBase(cp.trim(), baseP)) {
                    logProblem("read_compose_file: rejected path outside base: " + cp + " (base " + baseP + ")", null);
                    out.print("{\"success\":false,\"error\":\"Compose path must be inside " + escapeJsonStr(baseP) + "\"}");
                    return;
                }
                String found = null;
                for (String name : new String[]{"docker-compose.yml", "docker-compose.yaml"}) {
                    Path f = Paths.get(cp.trim(), name);
                    if (Files.isRegularFile(f)) { found = f.toString(); break; }
                }
                if (found == null) {
                    logProblem("read_compose_file: no compose file in " + cp, null);
                    out.print("{\"success\":false,\"error\":\"No docker-compose.yml or docker-compose.yaml found in this directory\"}");
                    return;
                }
                String text = new String(Files.readAllBytes(Paths.get(found)), StandardCharsets.UTF_8);
                if (text.length() > 256000) text = text.substring(0, 256000) + "\n... (file preview truncated)";
                out.print("{\"success\":true,\"fileName\":\"" + escapeJsonStr(Paths.get(found).getFileName().toString())
                    + "\",\"content\":\"" + escapeJsonStr(text) + "\"}");
                return;
            }

            if ("list_services".equals(action)) {
                out.print("{\"success\":true,\"config\":" + jsonConfig + "}");
                return;
            }

            if ("add_service".equals(action)) {
                String name = request.getParameter("name");
                String type = request.getParameter("type");
                String composePathParam = request.getParameter("composePath");
                String composeContent = request.getParameter("composeContent");
                String description = request.getParameter("description");
                String icon = request.getParameter("icon");
                String visibleParam = request.getParameter("visible");
                String manageableParam = request.getParameter("manageable");

                if (name == null || name.trim().isEmpty()) {
                    out.print("{\"success\":false,\"error\":\"Name is required\"}");
                    return;
                }

                synchronized (CONFIG_LOCK) {
                jsonConfig = readConfigFile(configPath);
                String id = makeId(name.trim());
                String finalComposePath = "";

                if ("docker-compose".equals(type)) {
                    if (composeContent != null && !composeContent.trim().isEmpty()) {
                        String basePath = "/srv/docker-compose";
                        try {
                            String bp = extractJsonField(jsonConfig, "composeBasePath");
                            if (bp != null && !bp.isEmpty()) basePath = bp;
                        } catch (Exception e) { logProblem("add_service: reading composeBasePath failed", e); }

                        finalComposePath = basePath + "/" + id;
                        Path composeDir = Paths.get(finalComposePath);
                        Files.createDirectories(composeDir);
                        Files.write(composeDir.resolve("docker-compose.yml"),
                            composeContent.getBytes(StandardCharsets.UTF_8));

                        try {
                            Runtime.getRuntime().exec(new String[]{
                                "chmod", "644", finalComposePath + "/docker-compose.yml"
                            }).waitFor();
                        } catch (Exception e) { logProblem("add_service: chmod on " + finalComposePath + " failed", e); }

                    } else if (composePathParam != null && !composePathParam.trim().isEmpty()) {
                        finalComposePath = composePathParam.trim();
                        String basePath = "/srv/docker-compose";
                        try {
                            String bp = extractJsonField(jsonConfig, "composeBasePath");
                            if (bp != null && !bp.isEmpty()) basePath = bp;
                        } catch (Exception e) { logProblem("add_service: reading composeBasePath failed", e); }
                        if (!isWithinBase(finalComposePath, basePath)) {
                            out.print("{\"success\":false,\"error\":\"Compose path must be inside " + escapeJsonStr(basePath) + "\"}");
                            return;
                        }
                        Path composeFile = Paths.get(finalComposePath, "docker-compose.yml");
                        if (!Files.exists(composeFile)) {
                            composeFile = Paths.get(finalComposePath, "docker-compose.yaml");
                            if (!Files.exists(composeFile)) {
                                out.print("{\"success\":false,\"error\":\"No docker-compose.yml found at: " + escapeJsonStr(finalComposePath) + "\"}");
                                return;
                            }
                        }
                    } else {
                        out.print("{\"success\":false,\"error\":\"Compose path or content required for docker-compose type\"}");
                        return;
                    }
                }

                boolean isVisible = visibleParam == null || "true".equals(visibleParam);
                // Management only makes sense for systemctl / docker-compose services.
                boolean isManageable = manageableParam != null && "true".equals(manageableParam)
                    && ("systemctl".equals(type) || "docker-compose".equals(type));

                StringBuilder svcJson = new StringBuilder();
                svcJson.append("{\"id\":\"").append(escapeJsonStr(id)).append("\"");
                svcJson.append(",\"name\":\"").append(escapeJsonStr(name.trim())).append("\"");
                svcJson.append(",\"icon\":\"").append(escapeJsonStr(icon != null ? icon : "fas fa-cube")).append("\"");
                svcJson.append(",\"type\":\"").append(escapeJsonStr(type != null ? type : "static")).append("\"");

                if ("systemctl".equals(type)) {
                    String svcName = request.getParameter("serviceName");
                    svcJson.append(",\"service\":\"").append(escapeJsonStr(svcName != null ? svcName : id)).append("\"");
                }

                if ("docker-compose".equals(type)) {
                    svcJson.append(",\"composePath\":\"").append(escapeJsonStr(finalComposePath)).append("\"");
                }

                svcJson.append(",\"description\":\"").append(escapeJsonStr(description != null ? description : "")).append("\"");

                String openUrl = request.getParameter("openUrl");
                if (openUrl != null && !openUrl.trim().isEmpty()) {
                    svcJson.append(",\"openUrl\":\"").append(escapeJsonStr(openUrl.trim())).append("\"");
                } else {
                    svcJson.append(",\"links\":[]");
                }

                svcJson.append(",\"visible\":").append(isVisible);
                svcJson.append(",\"manageable\":").append(isManageable);

                if (isManageable) {
                    svcJson.append(",\"actions\":[\"status\",\"start\",\"stop\",\"restart\",\"logs\"]");
                } else {
                    svcJson.append(",\"actions\":[]");
                }

                svcJson.append(",\"createdAt\":\"").append(java.time.Instant.now().toString()).append("\"}");
                String newService = svcJson.toString();

                // New services go to the end of the list, but the Docker and
                // Tomcat control entries stay last (as shown on the dashboard).
                int dockerStart = findServiceObjStart(jsonConfig, "docker");
                String newCfg;
                if (dockerStart != -1) {
                    newCfg = jsonConfig.substring(0, dockerStart) + newService + ",\n    " + jsonConfig.substring(dockerStart);
                } else {
                    int arrStart = findArrayStart(jsonConfig);
                    int arrEnd = (arrStart != -1) ? findArrayEnd(jsonConfig, arrStart) : -1;
                    if (arrEnd == -1) {
                        out.print("{\"success\":false,\"error\":\"Could not locate services array\"}");
                        return;
                    }
                    String prefix = jsonConfig.substring(0, arrEnd);
                    String sep = prefix.trim().endsWith("[") ? "\n    " : ",\n    ";
                    newCfg = prefix + sep + newService + "\n  " + jsonConfig.substring(arrEnd);
                }

                writeConfigFile(configPath, newCfg);
                out.print("{\"success\":true,\"id\":\"" + id + "\",\"message\":\"Service added successfully\"}");
                return;
                }
            }

            if ("update_service".equals(action)) {
                String id = request.getParameter("id");
                String name = request.getParameter("name");
                String description = request.getParameter("description");
                String icon = request.getParameter("icon");
                String visibleParam = request.getParameter("visible");
                String manageableParam = request.getParameter("manageable");

                if (id == null || id.trim().isEmpty()) {
                    out.print("{\"success\":false,\"error\":\"Service ID is required\"}");
                    return;
                }

                synchronized (CONFIG_LOCK) {
                jsonConfig = readConfigFile(configPath);
                int objStart = findServiceObjStart(jsonConfig, id);
                if (objStart == -1) {
                    out.print("{\"success\":false,\"error\":\"Service not found\"}");
                    return;
                }

                int objEnd = findMatchingBrace(jsonConfig, objStart);
                if (objEnd == -1) {
                    out.print("{\"success\":false,\"error\":\"Invalid config format\"}");
                    return;
                }

                String serviceBlock = jsonConfig.substring(objStart, objEnd + 1);

                if (name != null) serviceBlock = updateJsonField(serviceBlock, "name", name.trim());
                if (description != null) serviceBlock = updateJsonField(serviceBlock, "description", description);
                if (icon != null) serviceBlock = updateJsonField(serviceBlock, "icon", icon);
                if (visibleParam != null) serviceBlock = serviceBlock.replaceAll("\"visible\":\\s*(true|false)", "\"visible\":" + ("true".equals(visibleParam)));
                if (manageableParam != null) serviceBlock = serviceBlock.replaceAll("\"manageable\":\\s*(true|false)", "\"manageable\":" + ("true".equals(manageableParam)));

                String openUrl = request.getParameter("openUrl");
                if (openUrl != null) {
                    String trimmedOpen = openUrl.trim();
                    if (trimmedOpen.isEmpty()) {
                        serviceBlock = removeJsonField(serviceBlock, "openUrl");
                    } else {
                        serviceBlock = updateJsonField(serviceBlock, "openUrl", trimmedOpen);
                        serviceBlock = removeJsonField(serviceBlock, "links");
                    }
                }

                String newCfg = jsonConfig.substring(0, objStart) + serviceBlock + jsonConfig.substring(objEnd + 1);
                writeConfigFile(configPath, newCfg);

                out.print("{\"success\":true,\"message\":\"Service updated successfully\"}");
                return;
                }
            }

            if ("delete_service".equals(action)) {
                String id = request.getParameter("id");

                if (id == null || id.trim().isEmpty()) {
                    out.print("{\"success\":false,\"error\":\"Service ID is required\"}");
                    return;
                }

                synchronized (CONFIG_LOCK) {
                jsonConfig = readConfigFile(configPath);
                int objStart = findServiceObjStart(jsonConfig, id);
                if (objStart == -1) {
                    out.print("{\"success\":false,\"error\":\"Service not found\"}");
                    return;
                }

                int objEnd = findMatchingBrace(jsonConfig, objStart);

                // Deleting only removes the entry from this list. The service itself is
                // left alone: nothing is stopped or restarted, and no files on the server
                // are touched (that used to run `docker-compose stop` and `rm -rf`).
                String before = jsonConfig.substring(0, objStart);
                String after = jsonConfig.substring(objEnd + 1);

                if (before.trim().endsWith(",")) {
                    before = before.substring(0, before.lastIndexOf(","));
                } else if (after.trim().startsWith(",")) {
                    after = after.substring(after.indexOf(",") + 1);
                }

                writeConfigFile(configPath, before + after);
                out.print("{\"success\":true,\"message\":\"Service deleted successfully\"}");
                return;
                }
            }

            if ("toggle_visible".equals(action)) {
                String id = request.getParameter("id");

                if (id == null || id.trim().isEmpty()) {
                    out.print("{\"success\":false,\"error\":\"Service ID is required\"}");
                    return;
                }

                synchronized (CONFIG_LOCK) {
                jsonConfig = readConfigFile(configPath);
                int objStart = findServiceObjStart(jsonConfig, id);
                if (objStart == -1) {
                    out.print("{\"success\":false,\"error\":\"Service not found\"}");
                    return;
                }

                int objEnd = findMatchingBrace(jsonConfig, objStart);
                String serviceBlock = jsonConfig.substring(objStart, objEnd + 1);

                if (serviceBlock.matches("(?s).*\"visible\"\\s*:\\s*true.*")) {
                    serviceBlock = serviceBlock.replaceFirst("\"visible\"\\s*:\\s*true", "\"visible\":false");
                } else {
                    serviceBlock = serviceBlock.replaceFirst("\"visible\"\\s*:\\s*false", "\"visible\":true");
                }

                String newCfg = jsonConfig.substring(0, objStart) + serviceBlock + jsonConfig.substring(objEnd + 1);
                writeConfigFile(configPath, newCfg);

                out.print("{\"success\":true,\"message\":\"Visibility toggled\"}");
                return;
                }
            }

            if ("reorder_service".equals(action)) {
                String id = request.getParameter("id");
                String dir = request.getParameter("dir");
                String toIndexParam = request.getParameter("toIndex");

                if (id == null || id.trim().isEmpty() || (dir == null && toIndexParam == null)) {
                    out.print("{\"success\":false,\"error\":\"Missing id, dir or toIndex\"}");
                    return;
                }

                synchronized (CONFIG_LOCK) {
                jsonConfig = readConfigFile(configPath);
                int arrStart = findArrayStart(jsonConfig);
                int arrEnd = findArrayEnd(jsonConfig, arrStart);
                if (arrStart == -1 || arrEnd == -1) {
                    out.print("{\"success\":false,\"error\":\"Could not locate services array\"}");
                    return;
                }

                String[] items = splitTopLevel(jsonConfig, arrStart, arrEnd);
                if (items == null) {
                    out.print("{\"success\":false,\"error\":\"Failed to parse services array\"}");
                    return;
                }

                int fromIdx = -1;
                for (int i = 0; i < items.length; i++) {
                    if (items[i].contains("\"id\"")) {
                        String sId = extractIdSpaced(items[i]);
                        if (id.equals(sId)) { fromIdx = i; break; }
                    }
                }
                if (fromIdx == -1) {
                    out.print("{\"success\":false,\"error\":\"Service not found\"}");
                    return;
                }

                int toIdx;
                if (toIndexParam != null) {
                    try {
                        toIdx = Integer.parseInt(toIndexParam.trim());
                    } catch (NumberFormatException nfe) {
                        out.print("{\"success\":false,\"error\":\"Invalid toIndex\"}");
                        return;
                    }
                    if (toIdx < 0) toIdx = 0;
                    else if (toIdx >= items.length) toIdx = items.length - 1;
                } else {
                    if ("up".equals(dir) && fromIdx == 0) {
                        out.print("{\"success\":true,\"message\":\"Already at top\"}");
                        return;
                    }
                    if ("down".equals(dir) && fromIdx >= items.length - 1) {
                        out.print("{\"success\":true,\"message\":\"Already at bottom\"}");
                        return;
                    }
                    toIdx = "up".equals(dir) ? fromIdx - 1 : fromIdx + 1;
                }

                if (toIdx != fromIdx) {
                    // Move semantics: remove the item, then insert it at toIdx.
                    String moved = items[fromIdx];
                    for (int i = fromIdx; i < items.length - 1; i++) items[i] = items[i + 1];
                    for (int i = items.length - 1; i > toIdx; i--) items[i] = items[i - 1];
                    items[toIdx] = moved;
                }

                StringBuilder sb = new StringBuilder(jsonConfig.substring(0, arrStart + 1));
                sb.append("\n");
                for (int i = 0; i < items.length; i++) {
                    sb.append(items[i].trim());
                    if (i < items.length - 1) sb.append(",");
                    sb.append("\n");
                }
                sb.append(" ");
                sb.append(jsonConfig.substring(arrEnd));

                writeConfigFile(configPath, sb.toString());
                out.print("{\"success\":true,\"message\":\"Service reordered\"}");
                return;
                }
            }

            if ("batch_status".equals(action)) {
                int bsArrStart = findArrayStart(jsonConfig);
                String[] items2 = splitTopLevel(jsonConfig, bsArrStart, findArrayEnd(jsonConfig, bsArrStart));
                // Collect statuses concurrently; each probe is bounded by runProcess().
                java.util.Map<String, String> results = new java.util.HashMap<String, String>();
                if (items2 != null && items2.length > 0) {
                    int poolSize = Math.min(items2.length, 8);
                    ExecutorService pool = Executors.newFixedThreadPool(poolSize);
                    java.util.List<Callable<Void>> probes = new java.util.ArrayList<Callable<Void>>();
                    for (final String item : items2) {
                        probes.add(new Callable<Void>() {
                            public Void call() {
                                String sId = extractIdSpaced(item);
                                if (sId.isEmpty()) return null;
                                String sType = extractJsonField(item, "type");
                                String sService = extractJsonField(item, "service");
                                String sCompPath = extractJsonField(item, "composePath");
                                String status = probeStatus(sType, sId, sService, sCompPath);
                                synchronized (results) { results.put(sId, status); }
                                return null;
                            }
                        });
                    }
                    try {
                        pool.invokeAll(probes);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                    } finally {
                        pool.shutdown();
                    }
                }
                StringBuilder sb = new StringBuilder("{\"success\":true,\"statuses\":{");
                boolean first = true;
                if (items2 != null) {
                    for (String item : items2) {
                        String sId = extractIdSpaced(item);
                        if (sId.isEmpty()) continue;
                        String status = results.get(sId);
                        if (status == null) continue;
                        if (!first) sb.append(",");
                        first = false;
                        sb.append("\"").append(escapeJsonStr(sId)).append("\":\"").append(status).append("\"");
                    }
                }
                sb.append("}}");
                out.print(sb.toString());
                return;
            }

        } catch (Exception e) {
            // Log details server-side; never echo internals to the client.
            logProblem("action '" + action + "' failed (query: " + request.getQueryString() + ")", e);
            out.print("{\"success\":false,\"error\":\"An unexpected error occurred\"}");
            return;
        }
    }

    if (service == null || action == null) {
        out.print("{\"success\":false,\"error\":\"Missing service or action\"}");
        return;
    }

    String svcConfig = readConfigFile(configPath);
    int svcObjStart = findServiceObjStart(svcConfig, service);
    if (svcObjStart == -1) {
        out.print("{\"success\":false,\"error\":\"Invalid service\"}");
        return;
    }

    int svcObjEnd = findMatchingBrace(svcConfig, svcObjStart);
    String svcBlock = svcConfig.substring(svcObjStart, svcObjEnd + 1);

    String serviceType = extractJsonField(svcBlock, "type");
    String systemctlService = extractJsonField(svcBlock, "service");
    String svcComposePath = extractJsonField(svcBlock, "composePath");

    // Tomcat must never be stopped from the dashboard (mirrored in service_control.sh).
    if ("stop".equals(action) && "systemctl".equals(serviceType) && "tomcat".equals(systemctlService)) {
        out.print("{\"success\":false,\"error\":\"Tomcat cannot be stopped\"}");
        return;
    }

    String[] allowedActions = {"status", "start", "stop", "restart", "logs"};
    boolean actionAllowed = false;
    for (String a : allowedActions) if (a.equals(action)) { actionAllowed = true; break; }
    if (!actionAllowed) {
        out.print("{\"success\":false,\"error\":\"Invalid action\"}");
        return;
    }

    if (!svcBlock.contains("\"" + action + "\"")) {
        out.print("{\"success\":false,\"error\":\"Action '" + action + "' not allowed for this service\"}");
        return;
    }

    try {
        // Status goes through the shared probe (same code as Settings batch_status).
        if ("status".equals(action)) {
            String st = probeStatus(serviceType, service, systemctlService, svcComposePath);
            out.print("{\"success\":true,\"status\":\"" + st + "\"}");
            return;
        }

        if (!anyControlScriptExists()) {
            logProblem("action '" + action + "': no control script found in " + java.util.Arrays.toString(controlScriptCandidates()), null);
            out.print("{\"success\":false,\"error\":\"Control script not found on server (looked in "
                + escapeJsonStr(java.util.Arrays.toString(controlScriptCandidates())) + "). See WEB-INF/enable-sudo-tomcat.sh.\"}");
            return;
        }

        String[] args;
        if ("systemctl".equals(serviceType)) {
            args = new String[]{"systemctl", systemctlService, action, String.valueOf(lines)};
        } else if ("docker-compose".equals(serviceType)) {
            if (svcComposePath == null || svcComposePath.isEmpty()) {
                out.print("{\"success\":false,\"error\":\"No compose path configured\"}");
                return;
            }
            String baseP = extractJsonField(svcConfig, "composeBasePath");
            if (baseP == null || baseP.isEmpty()) baseP = "/srv/docker-compose";
            if (!isWithinBase(svcComposePath, baseP)) {
                out.print("{\"success\":false,\"error\":\"Compose path is outside the allowed base directory\"}");
                return;
            }
            args = new String[]{"docker-compose", service, action, String.valueOf(lines), svcComposePath};
        } else {
            out.print("{\"success\":false,\"error\":\"Service type not manageable\"}");
            return;
        }

        long timeoutSec = "logs".equals(action) ? 20 : ("status".equals(action) ? 10 : 60);
        int outCap = "logs".equals(action) ? (lines + 200) : 400;
        java.util.List<String> triedPaths = new java.util.ArrayList<String>();
        String result = runControlScript(timeoutSec, outCap, triedPaths, args);
        boolean scriptError = isScriptError(result);

        if ("logs".equals(action)) {
            if (scriptError) {
                logProblem("logs for " + service + " failed: " + result, null);
                out.print("{\"success\":false,\"error\":\"" + escapeJsonStr(result) + "\"}");
            } else {
                out.print("{\"success\":true,\"logs\":\"" + escapeJsonStr(result) + "\"}");
            }
        }
        else if (scriptError) {
            logProblem("action '" + action + "' for " + service + " failed: " + result, null);
            String hint = result.isEmpty()
                ? "No permitted control script. Add a NOPASSWD sudoers rule for one of: " + triedPaths
                : result;
            out.print("{\"success\":false,\"error\":\"" + escapeJsonStr(hint) + "\"}");
        }
        else {
            out.print("{\"success\":true,\"message\":\"Action " + action + " completed\"}");
        }
    } catch (Exception e) {
        logProblem("service '" + service + "' action '" + action + "' failed", e);
        out.print("{\"success\":false,\"error\":\"An unexpected error occurred\"}");
    }
%>