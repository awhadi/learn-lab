#!/bin/bash
# Generic service control script
# Usage: service_control.sh <type> <service-name> <action> <lines> [compose-path]
#   type: systemctl | docker-compose
#   service-name: systemctl service name OR docker-compose service id
#   action: status | start | stop | restart | logs
#   lines: number of log lines (default 100)
#   compose-path: path to docker-compose directory (required for docker-compose type)

TYPE=$1
SERVICE=$2
ACTION=$3
LINES=${4:-100}
COMPOSE_PATH=$5

# --- Defense-in-depth validation (independent of the JSP caller) ---
case "$TYPE" in
    systemctl|docker-compose) ;;
    *) echo "Error: Unknown type '$TYPE'. Must be 'systemctl' or 'docker-compose'"; exit 1 ;;
esac
case "$ACTION" in
    status|start|stop|restart|logs) ;;
    *) echo "Error: Unknown action '$ACTION'. Must be status|start|stop|restart|logs"; exit 1 ;;
esac
case "$LINES" in
    ''|*[!0-9]*) LINES=100 ;;
esac

get_compose_status() {
    local dir=$1
    cd "$dir" || { echo "stopped"; return 1; }
    if docker compose ps --format json 2>/dev/null | grep -q '"State":"running"'; then
        echo "running"
    else
        echo "stopped"
    fi
}

compose_action() {
    local dir=$1
    local act=$2
    cd "$dir" || exit 1
    case $act in
        start)
            docker compose up -d
            ;;
        stop)
            docker compose down
            ;;
        restart)
            docker compose down && docker compose up -d
            ;;
        logs)
            docker compose logs --tail="$LINES" 2>&1
            ;;
        status)
            get_compose_status "$dir"
            ;;
    esac
}

systemctl_action() {
    local svc=$1
    local act=$2
    case "$svc" in
        *[!A-Za-z0-9_.@-]*)
            echo "Error: invalid service name '$svc'"
            return 1
            ;;
    esac
    if [ "$svc" = "tomcat" ] && [ "$act" = "stop" ]; then
        echo "Error: tomcat cannot be stopped from the dashboard"
        return 1
    fi
    case $act in
        status)
            systemctl is-active "$svc" 2>/dev/null || echo "inactive"
            ;;
        start)
            systemctl start "$svc"
            ;;
        stop)
            systemctl stop "$svc"
            ;;
        restart)
            systemctl restart "$svc"
            ;;
        logs)
            journalctl -u "$svc" -n "$LINES" --no-pager 2>&1
            ;;
    esac
}

case $TYPE in
    systemctl)
        systemctl_action "$SERVICE" "$ACTION"
        ;;
    docker-compose)
        if [ -z "$COMPOSE_PATH" ]; then
            echo "Error: compose-path required for docker-compose type"
            exit 1
        fi
        case "$COMPOSE_PATH" in
            /srv/docker-compose/*) ;;
            *) echo "Error: compose path must be under /srv/docker-compose"; exit 1 ;;
        esac
        # Resolve symlinks: the real path must also stay under the allowed base.
        REAL_PATH=$(cd "$COMPOSE_PATH" 2>/dev/null && pwd -P) || { echo "Error: cannot access compose path '$COMPOSE_PATH'"; exit 1; }
        case "$REAL_PATH" in
            /srv/docker-compose/*) ;;
            *) echo "Error: compose path resolves outside /srv/docker-compose"; exit 1 ;;
        esac
        compose_action "$COMPOSE_PATH" "$ACTION"
        ;;
    *)
        echo "Error: Unknown type '$TYPE'. Must be 'systemctl' or 'docker-compose'"
        exit 1
        ;;
esac
