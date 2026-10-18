#!/bin/zsh
# Adds Study Timer to Vorssaint's notch island: a Study page, the countdown in
# the island's strip, and notices when a phase changes.
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

# Every file any version of the Study Timer patch touches.
TRACKED_FILES=(
  Sources/Vorssaint/Services/Notch/NotchTimerService.swift
  Sources/Vorssaint/Services/Notch/NotchTimerSupport.swift
  Sources/Vorssaint/Services/Notch/NotchSupport.swift
  Sources/Vorssaint/Core/NotchEditorStrings.swift
  Sources/Vorssaint/UI/Notch/NotchView.swift
  Sources/Vorssaint/UI/Settings/NotchContentEditor.swift
  Sources/Vorssaint/UI/Settings/NotchSettings.swift
)
NEW_FILES=(
  Sources/Vorssaint/Services/Notch/NotchStudyTimerBridge.swift
  Sources/Vorssaint/UI/Notch/NotchStudyTimerView.swift
)

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

ALREADY=0
if [[ -d "$DEST/.git" ]]; then
  echo "▸ Using the Vorssaint source in $DEST"
  cd "$DEST"
  if git apply --reverse --check "$PATCH" 2>/dev/null; then
    ALREADY=1
  elif [[ -f "${NEW_FILES[1]}" ]]; then
    # An earlier Study Timer patch is swapped for this one, as long as
    # nothing else in the folder changed.
    for changed in ${(f)"$(git status --porcelain | cut -c4-)"}; do
      if (( ! ${TRACKED_FILES[(Ie)$changed]} && ! ${NEW_FILES[(Ie)$changed]} )); then
        echo "$DEST has other changes ($changed). Commit or move them, or pick another folder:"
        echo "  ./install.sh ~/vorssaint-study-timer"
        exit 1
      fi
    done
    echo "▸ Removing the earlier Study Timer patch"
    git checkout --quiet -- "${TRACKED_FILES[@]}"
    rm -f "${NEW_FILES[@]}"
  fi
  if (( ! ALREADY )); then
    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo "$DEST has changes that aren't committed. Commit or move them, or pick another folder:"
      echo "  ./install.sh ~/vorssaint-study-timer"
      exit 1
    fi
    git fetch --quiet origin
  fi
else
  echo "▸ Downloading Vorssaint's source to $DEST"
  git clone --quiet https://github.com/vorssaint/vorssaint-utils.git "$DEST"
  cd "$DEST"
fi

if (( ALREADY )); then
  echo "▸ The Study Timer patch is already in place"
else
  git -c advice.detachedHead=false checkout --quiet "$COMMIT"
  echo "▸ Adding Study Timer to the notch"
  git apply "$PATCH"
fi

echo "▸ Building Vorssaint Developer (this takes a few minutes)"
./build.sh --dev --install

cat <<'DONE'

Done. Next:
  1. Quit your regular Vorssaint, so you don't get two islands.
  2. Open Vorssaint Developer and turn on Dynamic Island (and its Timer).
  3. Open the island and go to the new Study page, next to Timer.
     Pick a preset to start a session in Study Timer, or start one in
     Study Timer itself. The countdown also shows beside the camera, and
     the island pops out when a break starts, focus resumes, or the
     session is done.
DONE
