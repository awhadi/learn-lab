<%@ page import="java.io.*, java.nio.charset.StandardCharsets, java.nio.file.*, java.util.*" %>
<%@ page contentType="application/json; charset=UTF-8" %><%!
    final String SECRET_TOKEN = "K9mX2pR7vL5nB8wD4jH6fT3cY1aG0sE9qW2";

    private String readConfigFile(String path) {
        try {
            return new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "{\"services\":[],\"settings\":{\"composeBasePath\":\"/srv/docker-compose\"}}";
        }
    }

    private void writeConfigFile(String path, String content) throws Exception {
        Files.write(Paths.get(path), content.getBytes(StandardCharsets.UTF_8));
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
    String token = request.getParameter("token");
    if (token == null || !token.equals(SECRET_TOKEN)) {
        out.print("{\"success\":false,\"error\":\"Invalid or missing security token\"}");
        return;
    }

    String configPath = application.getRealPath("/WEB-INF/services.json");
    String service = request.getParameter("service");
    String action = request.getParameter("action");
    String linesParam = request.getParameter("lines");
    int lines = (linesParam != null && !linesParam.isEmpty()) ? Integer.parseInt(linesParam) : 100;

    if (action != null && (action.equals("list_services") || action.equals("add_service") ||
        action.equals("update_service") || action.equals("delete_service") || action.equals("toggle_visible") ||
        action.equals("reorder_service") || action.equals("batch_status"))) {

        try {
            String jsonConfig = readConfigFile(configPath);

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

                String id = makeId(name.trim());
                String finalComposePath = "";

                if ("docker-compose".equals(type)) {
                    if (composeContent != null && !composeContent.trim().isEmpty()) {
                        String basePath = "/srv/docker-compose";
                        try {
                            String settingsConfig = readConfigFile(configPath);
                            String bp = extractJsonField(settingsConfig, "composeBasePath");
                            if (bp != null && !bp.isEmpty()) basePath = bp;
                        } catch (Exception e) {}

                        finalComposePath = basePath + "/" + id;
                        Path composeDir = Paths.get(finalComposePath);
                        Files.createDirectories(composeDir);
                        Files.write(composeDir.resolve("docker-compose.yml"),
                            composeContent.getBytes(StandardCharsets.UTF_8));

                        try {
                            Runtime.getRuntime().exec(new String[]{
                                "chmod", "644", finalComposePath + "/docker-compose.yml"
                            }).waitFor();
                        } catch (Exception e) {}

                    } else if (composePathParam != null && !composePathParam.trim().isEmpty()) {
                        finalComposePath = composePathParam.trim();
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
                boolean isManageable = manageableParam != null && "true".equals(manageableParam);

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

                int insertIdx = jsonConfig.lastIndexOf("\"services\"");
                int bracketIdx = jsonConfig.indexOf("[", insertIdx);
                int firstItem = jsonConfig.indexOf("{", bracketIdx);

                String newCfg;
                if (firstItem > bracketIdx && jsonConfig.charAt(firstItem) == '{') {
                    newCfg = jsonConfig.substring(0, firstItem) + "\n    " + newService + ",\n" + jsonConfig.substring(firstItem).trim();
                } else {
                    newCfg = jsonConfig.substring(0, bracketIdx + 1) + "\n    " + newService + "\n  " + jsonConfig.substring(bracketIdx + 1);
                }

                writeConfigFile(configPath, newCfg);
                out.print("{\"success\":true,\"id\":\"" + id + "\",\"message\":\"Service added successfully\"}");
                return;
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

            if ("delete_service".equals(action)) {
                String id = request.getParameter("id");

                if (id == null || id.trim().isEmpty()) {
                    out.print("{\"success\":false,\"error\":\"Service ID is required\"}");
                    return;
                }

                int objStart = findServiceObjStart(jsonConfig, id);
                if (objStart == -1) {
                    out.print("{\"success\":false,\"error\":\"Service not found\"}");
                    return;
                }

                int objEnd = findMatchingBrace(jsonConfig, objStart);
                String serviceBlock = jsonConfig.substring(objStart, objEnd + 1);

                String typeCheck = serviceBlock.replaceAll("\\s+", "");
                if (typeCheck.contains("\"type\":\"docker-compose\"")) {
                    String composeP = extractJsonField(serviceBlock, "composePath");
                    if (composeP != null && !composeP.isEmpty()) {
                        try {
                            ProcessBuilder pb = new ProcessBuilder("sudo", "/opt/tomcat/webapps/ROOT/service_control.sh",
                                "docker-compose", id, "stop", "100", composeP);
                            pb.redirectErrorStream(true);
                            Process proc = pb.start();
                            proc.waitFor();
                        } catch (Exception e) {}
                        try {
                            Runtime.getRuntime().exec(new String[]{"sudo", "rm", "-rf", composeP}).waitFor();
                        } catch (Exception e) {}
                    }
                }

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

            if ("toggle_visible".equals(action)) {
                String id = request.getParameter("id");

                if (id == null || id.trim().isEmpty()) {
                    out.print("{\"success\":false,\"error\":\"Service ID is required\"}");
                    return;
                }

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

            if ("reorder_service".equals(action)) {
                String id = request.getParameter("id");
                String dir = request.getParameter("dir");

                if (id == null || id.trim().isEmpty() || dir == null) {
                    out.print("{\"success\":false,\"error\":\"Missing id or dir\"}");
                    return;
                }

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

                int toIdx = "up".equals(dir) ? fromIdx - 1 : fromIdx + 1;
                if ("up".equals(dir) && fromIdx == 0) {
                    out.print("{\"success\":true,\"message\":\"Already at top\"}");
                    return;
                }
                if ("down".equals(dir) && fromIdx >= items.length - 1) {
                    out.print("{\"success\":true,\"message\":\"Already at bottom\"}");
                    return;
                }

                String tmp = items[fromIdx];
                items[fromIdx] = items[toIdx];
                items[toIdx] = tmp;

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

            if ("batch_status".equals(action)) {
                StringBuilder sb = new StringBuilder("{\"success\":true,\"statuses\":{");
                String[] items2 = splitTopLevel(jsonConfig, findArrayStart(jsonConfig), findArrayEnd(jsonConfig, findArrayStart(jsonConfig)));
                boolean first = true;
                if (items2 != null) {
                    for (String item : items2) {
                        String sId = extractIdSpaced(item);
                        if (sId.isEmpty()) continue;
                        String sType = extractJsonField(item, "type");
                        String sService = extractJsonField(item, "service");
                        String sCompPath = extractJsonField(item, "composePath");
                        String status = "static";
                        if ("systemctl".equals(sType) && sService != null) {
                            try {
                                ProcessBuilder pb = new ProcessBuilder("systemctl", "is-active", sService);
                                pb.redirectErrorStream(true);
                                Process p = pb.start();
                                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));
                                StringBuilder sb2 = new StringBuilder();
                                String ln;
                                while ((ln = r.readLine()) != null) sb2.append(ln);
                                p.waitFor();
                                String result = sb2.toString().trim();
                                if (result.equals("active")) status = "running";
                                else if (result.equals("inactive") || result.equals("dead")) status = "stopped";
                                else status = "unknown";
                            } catch (Exception ex) { status = "unknown"; }
                        } else if ("docker-compose".equals(sType) && sCompPath != null) {
                            try {
                                ProcessBuilder pb = new ProcessBuilder("docker", "compose", "ps", "--format", "json");
                                pb.directory(new java.io.File(sCompPath));
                                pb.redirectErrorStream(true);
                                Process p = pb.start();
                                BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));
                                StringBuilder sb2 = new StringBuilder();
                                String ln;
                                while ((ln = r.readLine()) != null) sb2.append(ln);
                                p.waitFor();
                                String result = sb2.toString().trim();
                                if (!result.isEmpty() && result.contains("\"State\":\"running\"")) status = "running";
                                else if (result.isEmpty()) status = "stopped";
                                else status = "unknown";
                            } catch (Exception ex) { status = "unknown"; }
                        }
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
            out.print("{\"success\":false,\"error\":\"" + escapeJsonStr(e.getMessage()) + "\"}");
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
        String[] cmd;
        if ("systemctl".equals(serviceType)) {
            cmd = new String[]{"sudo", "/opt/tomcat/webapps/ROOT/service_control.sh",
                "systemctl", systemctlService, action, String.valueOf(lines)};
        } else if ("docker-compose".equals(serviceType)) {
            if (svcComposePath == null || svcComposePath.isEmpty()) {
                out.print("{\"success\":false,\"error\":\"No compose path configured\"}");
                return;
            }
            cmd = new String[]{"sudo", "/opt/tomcat/webapps/ROOT/service_control.sh",
                "docker-compose", service, action, String.valueOf(lines), svcComposePath};
        } else {
            out.print("{\"success\":false,\"error\":\"Service type not manageable\"}");
            return;
        }

        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.redirectErrorStream(true);
        Process proc = pb.start();
        BufferedReader reader = new BufferedReader(new InputStreamReader(proc.getInputStream(), StandardCharsets.UTF_8));
        StringBuilder output = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            output.append(line).append("\n");
        }
        proc.waitFor();
        String result = output.toString().trim();

        if ("status".equals(action)) {
            String status = "unknown";
            if (result.equals("active") || result.equals("running")) status = "running";
            else if (result.equals("inactive") || result.equals("stopped")) status = "stopped";
            else if (result.isEmpty()) status = "stopped";
            out.print("{\"success\":true,\"status\":\"" + status + "\"}");
        }
        else if ("logs".equals(action)) {
            String escapedLogs = escapeJsonStr(result);
            out.print("{\"success\":true,\"logs\":\"" + escapedLogs + "\"}");
        }
        else {
            out.print("{\"success\":true,\"message\":\"Action " + action + " completed\"}");
        }
    } catch (Exception e) {
        out.print("{\"success\":false,\"error\":\"" + escapeJsonStr(e.getMessage()) + "\"}");
    }
%>