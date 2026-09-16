#!/bin/bash
# ============================================================
# enable-sudo-tomcat.sh
# Add passwordless sudo for tomcat to run WEB-INF/service_control.sh
#
# Run ON THE SERVER as root:
#   sudo bash WEB-INF/enable-sudo-tomcat.sh
# ============================================================
set -e

SUDOERS_FILE="/etc/sudoers.d/tomcat"
# Allow BOTH the new WEB-INF location and the legacy web-root location, so any
# deployment layout keeps working (the old path is only used if the file exists).
RULE="tomcat  ALL=(ALL) NOPASSWD: /opt/tomcat/webapps/ROOT/WEB-INF/service_control.sh"
RULE_LEGACY="tomcat  ALL=(ALL) NOPASSWD: /opt/tomcat/webapps/ROOT/service_control.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root. Try: sudo bash WEB-INF/enable-sudo-tomcat.sh"
    exit 1
fi

if [ -f "$SUDOERS_FILE" ] && grep -q "tomcat" "$SUDOERS_FILE" 2>/dev/null; then
    echo "Existing $SUDOERS_FILE:"
    cat "$SUDOERS_FILE"
    echo ""
    if [ -t 0 ]; then
        printf "Overwrite? [y/N] "
        read -r REPLY
        [ "$REPLY" != "y" ] && [ "$REPLY" != "Y" ] && { echo "Aborted."; exit 0; }
    else
        echo "Non-interactive shell: overwriting without prompt."
    fi
fi

printf '%s\n%s\n' "$RULE" "$RULE_LEGACY" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
    echo "Done:"
    cat "$SUDOERS_FILE"
else
    echo "Syntax error — rolling back"
    rm -f "$SUDOERS_FILE"
    exit 1
fi
