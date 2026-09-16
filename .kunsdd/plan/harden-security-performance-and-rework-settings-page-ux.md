# Harden security/performance + rework Settings page UX (Pega Lab Dashboard)

## Summary
Small Tomcat/JSP dashboard (`index.jsp` + `js/script.js`, JSON API `service_api.jsp`, sudo wrapper `service_control.sh`, config `WEB-INF/services.json`). This plan (1) implements code-level security + performance hardening **without adding an auth boundary** (confirmed: keep the lab open), (2) reworks the Settings page so the visibility toggle only shows/hides, delete becomes an icon-only × and is disabled for the Docker/Tomcat infra rows, and each manageable service row gets inline Start/Stop/Restart buttons based on live status, plus (3) adds mouse drag-and-drop reordering. Tomcat can never be stopped (server **and** UI enforced); Restart stays allowed. Removing the version-badge dropdown menu is deferred.

## Confirmed decisions
- **No auth/login** — harden code, keep dashboard + API open. Residual risk accepted by owner.
- **Delete (×) disabled** for the infra rows only: ids `docker` (Docker engine) and `tomcat-service` (Tomcat). Other rows keep delete.
- **Tomcat**: Stop is never offered (UI + server rejects it); Restart shown when running; Start shown when stopped.
- **Drag & drop** added in addition to the existing up/down buttons (buttons stay as fallback/mobile).
- Toggle = visibility only. Never stops services, never asks about stopping.

---

## A. Security hardening (no new dependencies)

### A1. Remove the worthless shared secret
The token is printed to every anonymous visitor (`index.jsp`) and committed to git (`service_api.jsp:3`), so it protects nothing and only leaks into URLs/logs/history/referrers.
- `service_api.jsp:3` — delete `SECRET_TOKEN`.
- `service_api.jsp:224-227` — delete the token gate (API becomes explicitly open; document in a comment).
- `index.jsp` (`window.SERVICES_CONFIG.token`) and `js/script.js:1-2` (`API_TOKEN` + fallback) — delete.
- `js/script.js:75-85` `callServiceAPI` — stop appending `token=` to the URL.
- Do **not** remove the check yet if owner prefers keeping an optional env-driven token (`System.getenv("LAB_ADMIN_TOKEN")`) — default decision: remove entirely per "keep lab open".

### A2. Remove live passwords from public content
- `WEB-INF/services.json` — strip plaintext passwords from descriptions served to anyone: Pega demo (`demoadmin1/2 / awhadi.online`), LDAP `testuser`, pgAdmin (`admin@awhadi.online / awhadi.online`). Keep usernames + a neutral pointer (e.g. "credentials shared by lab admin") or owner-approved copy.
- Flag: those creds are already burned (public page + git history); real fix is rotating lab passwords — out of scope here, note in summary.

### A3. Kill stored-XSS paths (config is attacker-editable since API is open)
- `index.jsp` — add DOMPurify from cdnjs (consistent with existing CDN usage).
- `js/script.js` — add helper `sanitizeHtml(s)` (DOMPurify, falling back to `escapeHtml`). Sanitize every config-derived string before it touches `innerHTML`:
  - `renderServicesList` item template (~lines 124-149) — currently injects raw `svc.icon` into an attribute and `svc.description`-style content.
  - `loadAndRenderServices` card HTML (~lines 666-689) — raw `${svc.description}` and raw `href="${openHref}"`.
  - error-message templates (694).
- `resolveOpenUrl` (621) — restrict scheme: allow `http(s)`/relative only; reject `javascript:`, `data:`, `vbscript:`.
- Card open links — add `rel="noopener noreferrer"`.

### A4. Server-side control hardening (defense in depth)
- `service_api.jsp` (~233) — validate `lines`: clamp to 1..2000 (reject non-numeric with JSON 400 instead of an uncaught `NumberFormatException` → today leaks a 500).
- **Tomcat stop guard**: in the action branch, if `systemctlService` == `"tomcat"` && action == `"stop"` → return `{"success":false,"error":"Tomcat cannot be stopped"}`. (UI also hides the button.)
- **composePath allowlist**: helper `isWithinBase(path, base)` (canonicalize; `toRealPath` when the dir exists). Enforce on `add_service` composePathParam (~295-307), on `delete_service` before `sudo rm -rf` (~430-437), and on run actions (systemctl/docker-compose branch ~645-665). Base = configured `composeBasePath` (`/srv/docker-compose`).
- Don't echo raw `e.getMessage()` to clients (config-mutation catch ~line 480s and action catch ~680s) — return a generic error and log server-side (avoids internal-path disclosure).

### A5. Hardening in the shell layer
- `service_control.sh` top: whitelist `TYPE` ∈ {systemctl, docker-compose}, `ACTION` ∈ {status,start,stop,restart,logs}; reject anything else before dispatch.
- Docker-compose branch: refuse `COMPOSE_PATH` whose `realpath` is not under `/srv/docker-compose` (defense even if JSP is bypassed).
- systemctl branch: validate unit name against `^[A-Za-z0-9_.@-]+$`; refuse `start|stop|restart|logs` (any action) when unit resolves to `tomcat` except `status` — second independent Tomcat-stop guard (mirrors A4).

### A6. Config write integrity (correctness + race safety)
- `service_api.jsp`: add `static final Object CONFIG_LOCK`; wrap each read-mutate-write flow (add/update/delete/toggle/reorder) in `synchronized (CONFIG_LOCK)`.
- Replace `writeConfigFile` (14) with atomic write: write to `<file>.tmp` then `Files.move(..., REPLACE_EXISTING, ATOMIC_MOVE)`; on failure the original file stays intact.

---

## B. Performance fixes

### B1. Don't block a Tomcat thread forever (DoS/robustness)
- Central subprocess helper in `service_api.jsp` that: starts the process, reads output **bounded** (≤ ~4000 lines / ~512 KB), then `waitFor(timeout)` (start/stop/restart 60 s, logs 20 s, status 10 s) and `destroyForcibly()` on timeout. Used by the single-service action handler (~658+), `batch_status` (~563/578) and delete/stop (`~430-437`).
- `lines` already clamped in A4 → bounds `journalctl -n` / `docker compose logs --tail`.

### B2. `batch_status` parallelism
- Run the per-service probes concurrently with a fixed pool (`Executors.newFixedThreadPool(min(8, n))`), each bounded by the B1 timeout, then merge results. Currently serial → N subprocesses per page load.

### B3. Config read cost (minor)
- `readConfigFile` (7) reads the whole file per request. File is ~7 KB, so **not worth caching** — note in code comment. Optional (owner choice): rework the hand-rolled JSON string surgery on a real parser if a single Gson jar in `WEB-INF/lib` is acceptable; otherwise keep string ops (now safe under the CONFIG_LOCK + atomic write). Default: keep string ops, no new jar.

### B4. Frontend micro-fixes
- `startTime` (script.js ~38-44): pause the clock while `document.hidden` (visibilitychange) instead of DOM updates every 500 ms forever; interval 1 s is enough.

---

## C. Settings page UX rework (`js/script.js` + `css/style.css`)

### C1. Visibility toggle = show/hide only
- Rewrite `toggleServiceVisibility` (238-~290): single `toggle_visible` call → `loadServicesList()`. Delete the entire confirm/stop cascade (status check → stop → toggle). On failure revert the checkbox and alert. No dialogs about stopping, no "service down".

### C2. Row action buttons (Start/Stop/Restart) next to status
- In `renderServicesList` (~114): add a per-row action slot, e.g. `<div class="svc-actions" data-id="…">`, and keep the existing badge.
- Keep a module-level `currentServices` array (set in `renderServicesList`) and change `fetchAllStatuses` (~194) to use it — this also fixes the pre-existing bug where its `.catch` references an out-of-scope `services` (would throw `ReferenceError` on failure).
- After statuses arrive, populate the slot per row:
  - not manageable/static → nothing (badge stays `—`).
  - **running** → `Stop` + `Restart`; **stopped** → `Start`; **unknown** → nothing (badge says unknown).
  - Respect each service's `actions` array from config (e.g. Docker engine row has only `restart` → running shows Restart only).
  - **Tomcat (`id === 'tomcat-service'`): never render Stop** (Restart when running, Start when stopped).
- New `rowAction(id, action)` helper: `confirm()` for stop/restart (same wording style as main modal), disable the clicked button + "…" while running, call API, on success re-run `fetchAllStatuses(currentServices)`; `alert` on error.
- For consistency also hide the Stop button for Tomcat in the main-page modal `renderModalButtons` (~490s) so both surfaces agree (server still enforces).

### C3. Delete = icon-only ×, disabled for infra rows
- Replace the delete button (144): icon-only `<i class="fas fa-times"></i>`, `title`/`aria-label` = `Delete <name>`, remove the " Delete" text.
- Disable when `id ∈ { 'docker', 'tomcat-service' }` (`DISABLED_DELETE_IDS` const): `disabled` + a CSS dimmed state + title "Core service — cannot delete".
- Adjust `deleteService` (430) confirm copy (warn that docker-compose deletes stop the stack and remove its files; remove that warning for systemctl rows).
- Row cleanup: skip attaching click handlers on disabled delete buttons (or guard in handler).

### C4. Mouse drag-and-drop sorting
- Make `.service-list-item` rows `draggable`; wire dragstart/dragover/drop/dragend in `renderServicesList`. Compute target index from pointer position; call new `reorderServiceTo(id, toIndex)`; refresh list on success.
- Keep existing `reorderService(id, dir)` (224) + up/down buttons as keyboard/fallback path.
- CSS additions (`style.css`, reuse existing theme variables): `.svc-actions` layout, small inline action buttons (reuse `btn-start/btn-stop/btn-restart` visual language), `.btn-delete[disabled]` dimmed, `.service-list-item.dragging { opacity }`, `.drag-over` highlight, `cursor: grab`.
- Note: drag & drop is desktop-only; buttons remain for touch/small screens (already in DOM).

---

## D. Backend for reorder-to-index
- `service_api.jsp` `reorder_service` (~452-521): accept optional `toIndex` param; when present clamp to `[0, items.length-1]` and swap `fromIdx → toIdx`; otherwise keep current `up`/`down` behavior. Output format unchanged (server rebuilds the array the same way).

---

## Files touched
1. `js/script.js` — token removal; sanitize; toggle rewrite; row actions; icon-only disabled delete; drag&drop; clock pause; modal Stop suppression for Tomcat; `fetchAllStatuses` fix. (largest change)
2. `service_api.jsp` — remove token; lines clamp; Tomcat-stop guard; compose-path allowlist; generic errors; CONFIG_LOCK + atomic writes; subprocess timeouts/output caps; parallel `batch_status`; `toIndex` in reorder.
3. `index.jsp` — drop `SERVICES_CONFIG.token`; add DOMPurify script tag.
4. `WEB-INF/services.json` — remove plaintext passwords from descriptions (owner-approved copy).
5. `service_control.sh` — TYPE/ACTION whitelist, compose-path confinement, unit-name regex, Tomcat guard.
6. `css/style.css` — new row/action/drag styles.
7. `WEB-INF/web.xml` — only if generic error page desired (optional; skip unless stack traces are observed in prod).

## Verification (manual, no test suite exists)
- **Security**: no `token=` in any request/network tab; no password strings in `list_services` response; `<script>`/`onerror` payloads planted in `description`/`icon` do **not** execute (main page + settings list); `?lines=abc` returns JSON 400; `lines=999999` clamped; direct API `stop` on `tomcat-service` returns error; `add_service` with `composePath=/etc` rejected; deleting the Docker/Tomcat infra rows impossible from UI.
- **Performance**: open a service's logs/status — request returns even if `docker compose` hangs (timeout kills it); settings modal loads once with statuses in parallel; clock stops updating when the tab is hidden.
- **UX flows**: toggle hides/shows the card on the main page and never touches the service; row shows Start/Stop/Restart matching status (pgAdmin running → Stop+Restart; stopped → Start; Docker → Restart only; Tomcat running → Restart only, no Stop); delete buttons are × only, dimmed+disabled for Docker/Tomcat; drag a row between others → order persists after reload; up/down buttons still work; service stop/start/restart from a row behaves like the version-header modal.
- Deploy to the lab Tomcat and run the above against the live app; verify `services.json` still parses after CRUD + drag (no corruption across rapid clicks).

## Deferred / not in this change
- Remove the version-badge dropdown menu + its options (Tomcat Manager / Host Manager / Restart Tomcat / Restart Docker) and the related modal code — owner will ask separately ("later").
- Real auth boundary (recommend reverse-proxy Basic Auth on `/service_api.jsp` or in-app login) — out of scope by decision; keep the API open but note the risk in a comment.
- Optional Gson refactor of JSON string surgery (only if jars are acceptable).
- Lab password rotation (creds are already public in git history + page).

## Risks / notes
- Removing the token and opening the API is the owner's explicit choice; A2-A6 reduce blast radius (no live creds, no stored XSS, path-confined compose/rm, bounded subprocesses, atomic config) but anyone who can reach the site can still start/stop/restart configured services — this is inherent to "keep lab open".
- Tomcat stop is blocked at the API and shell layers in addition to the UI, so even crafted requests cannot stop it.
- Drag-and-drop reorder and inline actions depend on the existing `reorder_service`/`batch_status` endpoints; both already exist — only small extensions (`toIndex`) are added.
