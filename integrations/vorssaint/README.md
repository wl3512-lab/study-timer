# Study Timer in Vorssaint's notch

Shows your [Study Timer](https://github.com/bhauw/study-timer) session in [Vorssaint](https://github.com/vorssaint/vorssaint-utils)'s notch island, the same way Vorssaint shows Codex and other AI agents:

- **While a session runs**, the island's strip shows a live countdown beside the camera. Hover or click to open the timer page, where pause, skip and stop control Study Timer.
- **When something changes**, the island pops out with a notice, like Vorssaint's "Codex finished" notice: *Study session started*, *Break time · Round 1 done · 5 min break*, *Back to focus · Round 2 of 4*, *Study timer paused* or *resumed*, and *Study session complete*, which Vorssaint's companion cheers.
- A timer you start in Vorssaint itself always wins. When you stop it, the Study Timer session comes back.
- The island never makes its own sounds for Study Timer; Study Timer's chimes and notifications already do that.

## What you need

- An Apple Silicon Mac with macOS 14 or later
- The Xcode Command Line Tools (the install script offers to install them)
- **Study Timer** itself, from the [Releases](https://github.com/bhauw/study-timer/releases) page, version 2.1 or later

## Install

1. Unzip **StudyTimer-Vorssaint-Island.zip**.
2. Open Terminal and run:
   ```bash
   cd ~/Downloads/StudyTimer-Vorssaint-Island
   ./install.sh
   ```
   (Change the first line if you unzipped it somewhere else.)
3. The script downloads Vorssaint's source to `~/vorssaint-utils`, adds the Study Timer patch, and builds **Vorssaint Developer**, a separate app with its own settings. Your regular Vorssaint isn't changed.
4. Quit your regular Vorssaint, open **Vorssaint Developer**, and turn on the notch island and its **Timer** module.
5. Start a session in Study Timer.

To remove it, quit Vorssaint Developer and delete it from Applications, then open your regular Vorssaint again.

## Good to know

- This is a personal build. It doesn't get Vorssaint's official updates. To update, pull the latest Vorssaint and apply the patch again. If the patch no longer fits a newer Vorssaint, the script uses the version it was made for.
- Vorssaint is open source under GPL-3.0. The patch only adds a listener (`NotchStudyTimerBridge.swift` and a few lines in Vorssaint's timer), and no Study Timer code goes into Vorssaint. Vorssaint's name and icon are its trademarks, so share this patch and script, not a built app.

## How it works

Study Timer announces its session to other apps on your Mac whenever it changes (start, pause, skip, end, join), and whenever another app asks. It sends the session itself, not a countdown every second, so this costs nothing. The patched island works out the current phase using the same schedule Study Timer uses, shows it as a pomodoro in its timer strip, and announces phase changes.

| Notification | Direction | userInfo |
| --- | --- | --- |
| `com.braxtonhauw.studytimer.state` | Study Timer → other apps | `active` (Bool), `focus`, `brk`, `rounds` (Int), `startUtc`, `pausedAt` (Double, 0 = running), `code` (String) |
| `com.braxtonhauw.studytimer.request` | other apps → Study Timer | none; Study Timer replies with `state` |
| `com.braxtonhauw.studytimer.command` | other apps → Study Timer | `action`: `togglePause`, `skip` or `end` |

Any app can listen for these, so the same session could show in other tools too.
