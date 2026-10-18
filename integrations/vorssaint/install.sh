#!/bin/zsh
# Adds Study Timer to Vorssaint's notch island.
# Builds your own "Vorssaint Developer" app from Vorssaint's source with the
# Study Timer patch. Your regular Vorssaint is not touched.
#
#   ./install.sh                  uses ~/vorssaint-utils
#   ./install.sh ~/some/folder    uses another folder
set -euo pipefail

HERE="${0:A:h}"
PATCH="$HERE/study-timer-island.patch"
DEST="${1:-$HOME/vorssaint-utils}"
COMMIT=5d1ffa07c83665c83123fdf734a70843cd1f8771   # the Vorssaint version this patch fits

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Vorssaint needs an Apple Silicon Mac."; exit 1
fi
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]]; then
  echo "Vorssaint needs macOS 14 or later."; exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Installing the Xcode Command Line Tools first. Run ./install.sh again when that finishes."
  xcode-select --install
  exit 1
fi

if [[ -d "$DEST/.git" ]]; then
  echo "▸ Using the Vorssaint source in $DEST"
  cd "$DEST"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "$DEST has changes that aren't committed. Commit or move them, or pick another folder:"
    echo "  ./install.sh ~/vorssaint-study-timer"
    exit 1
  fi
  git fetch --quiet origin
else
  echo "▸ Downloading Vorssaint's source to $DEST"
  git clone --quiet https://github.com/vorssaint/vorssaint-utils.git "$DEST"
  cd "$DEST"
fi

git -c advice.detachedHead=false checkout --quiet "$COMMIT"

if git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "▸ The Study Timer patch is already in place"
else
  echo "▸ Adding Study Timer to the notch"
  git apply "$PATCH"
fi

echo "▸ Building Vorssaint Developer (this takes a few minutes)"
./build.sh --dev --install

cat <<'DONE'

Done. Next:
  1. Quit your regular Vorssaint, so you don't get two islands.
  2. Open Vorssaint Developer, turn on the notch island, and turn on its Timer.
  3. Start a session in Study Timer. The countdown shows around the notch,
     and the island pops out when a break starts, focus resumes, or the
     session is done.
DONE
