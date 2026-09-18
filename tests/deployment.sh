#!/bin/sh
# Static contract checks only: no system services are installed or started.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
UNIT="$ROOT/examples/systemd/swapai.service"
require_line() {
    if ! grep -Fqx "$1" "$UNIT"; then
        printf 'Missing deployment unit contract: %s\n' "$1" >&2
        exit 1
    fi
}
require_line 'Type=oneshot'
require_line 'RemainAfterExit=yes'
require_line 'User=swapai'
require_line 'Group=swapai'
require_line 'Environment=SWAPAI_HOST=127.0.0.1'
require_line 'Environment=SWAPAI_PORT=11435'
require_line 'Environment=SWAPAI_CONFIG_HOME=/home/swapai/.config/swapai'
require_line 'Environment=SWAPAI_STATE_HOME=/home/swapai/.local/state/swapai'
require_line 'ExecStart=/home/swapai/.local/bin/swapai switch pi-cpu'
require_line 'ExecStop=/home/swapai/.local/bin/swapai stop'
require_line 'KillMode=control-group'
require_line 'TimeoutStartSec=15min'
require_line 'TimeoutStopSec=45s'
if grep -Eq '^(Restart|PIDFile|ExecStartPre)=' "$UNIT"; then
    printf 'Unexpected supervision or pre-start action in oneshot example\n' >&2
    exit 1
fi
# Parse every shell example separately, without executing installer/admin commands.
awk '
    /^```sh$/ { in_shell = 1; print "("; next }
    /^```$/ && in_shell { in_shell = 0; print ")"; next }
    in_shell { print }
    END { if (in_shell) exit 1 }
' "$ROOT/docs/raspberry-pi.md" | sh -n
printf 'Deployment static contracts and documented shell syntax passed (not live systemd/Pi validation)\n'
