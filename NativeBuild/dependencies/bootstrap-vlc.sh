#!/bin/bash
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
export PATH="${VISTA_BUILD_TOOLS:+$VISTA_BUILD_TOOLS:}/opt/homebrew/opt/m4/bin:/opt/homebrew/opt/libtool/libexec/gnubin:$PATH"
export M4="${M4:-$(command -v m4)}" ACLOCAL_PATH="${ACLOCAL_PATH:-/opt/homebrew/share/aclocal}"
cd "$D/source/vlc"
./bootstrap > "$D/logs/vlc-bootstrap.log" 2>&1
