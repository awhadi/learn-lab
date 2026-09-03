#!/bin/bash
# ============================================================
# enable-sudo-tomcat.sh
# Add passwordless sudo for tomcat to run service_control.sh
#
# Run ON THE SERVER as root:
#   sudo bash enable-sudo-tomcat.sh
# ============================================================
set -e

SUDOERS_FILE="/etc/sudoers.d/tomcat"
RULE="tomcat  ALL=(ALL) NOPASSWD: /opt/tomcat/webapps/ROOT/service_control.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root. Try: sudo bash enable-sudo-tomcat.sh"
    exit 1
fi

if [ -f "$SUDOERS_FILE" ] && grep -q "tomcat" "$SUDOERS_FILE" 2>/dev/null; then
    echo "Rule already exists:"
    cat "$SUDOERS_FILE"
    echo ""
    printf "Overwrite? [y/N] "
    read -r REPLY
    [ "$REPLY" != "y" ] && [ "$REPLY" != "Y" ] && { echo "Aborted."; exit 0; }
fi

echo "$RULE" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
    echo "Done: $RULE"
else
    echo "Syntax error — rolling back"
    rm -f "$SUDOERS_FILE"
    exit 1
fi
