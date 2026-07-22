#!/bin/sh

set -eu

INSTALL_DIR=${SWAPAI_INSTALL_DIR:-$HOME/.local/bin}
SHARE_DIR=${SWAPAI_SHARE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/swapai}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

mkdir -p "$INSTALL_DIR" "$SHARE_DIR/bin" "$SHARE_DIR/lib" "$SHARE_DIR/examples"
cp "$SCRIPT_DIR/bin/swapai" "$SHARE_DIR/bin/swapai"
cp "$SCRIPT_DIR/lib/swapai.sh" "$SHARE_DIR/lib/swapai.sh"
cp "$SCRIPT_DIR/examples/profiles.tsv" "$SHARE_DIR/examples/profiles.tsv"
chmod +x "$SHARE_DIR/bin/swapai"
ln -sf "$SHARE_DIR/bin/swapai" "$INSTALL_DIR/swapai"

printf 'Installed SwapAI at %s/swapai\n' "$INSTALL_DIR"
case :$PATH: in
    *:"$INSTALL_DIR":*) ;;
    *) printf 'Add %s to your PATH.\n' "$INSTALL_DIR" ;;
esac
