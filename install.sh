#!/usr/bin/env bash
# Symlink cr into ~/.local/bin (or $PREFIX/bin).
set -euo pipefail
SRC="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr"
DEST="${PREFIX:-$HOME/.local}/bin"
mkdir -p "$DEST"
ln -sf "$SRC" "$DEST/cr"
echo "Linked $DEST/cr -> $SRC"
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo "Note: $DEST is not on your PATH. Add:  export PATH=\"$DEST:\$PATH\"" ;;
esac
command -v jq >/dev/null || echo "Note: install jq (brew install jq)."
echo "Done. Try:  cr register-default && cr add <name>"
