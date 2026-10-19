# Study Timer in Vorssaint's notch

Puts your [Study Timer](https://github.com/wl3512-lab/study-timer) inside [Vorssaint](https://github.com/vorssaint/vorssaint-utils)'s notch island, the way Vorssaint shows Codex and other AI agents:

- **A Study page in the island**, next to Timer, Music and Agents. It shows Study Timer's progress ring with its breathing aura, the countdown, the round dots, and pause, skip, stop and copy code. With no session running, pick a preset (or your Vorssaint pomodoro settings) to start one. If Study Timer is closed, the page has a button to open it.
- **A live countdown beside the camera** while a session runs, in the island's timer strip.
- **Pop-out notices when something changes**, like Vorssaint's "Codex finished" notice: *Study session started*, *Break time · Round 1 done · 5 min break*, *Back to focus · Round 2 of 4*, *Study timer paused* or *resumed*, and *Study session complete*, which Vorssaint's companion cheers.
- **Vorssaint's Pomodoro runs in Study Timer.** With Study Timer open, starting a Pomodoro on the island's Timer page starts a Study Timer session with your Vorssaint focus, break and session settings. With Study Timer closed, Vorssaint's own timer works as usual.
- **A timer you start in Vorssaint always wins.** A plain timer or stopwatch you start there replaces the Study Timer countdown in the strip; when you stop it, the Study Timer session shows again.
- **No double sounds.** The island never plays its own sounds for Study Timer; Study Timer's chimes and notifications already do that.

Every button in the island sends a command to Study Timer, which owns the session. Your share code, chimes, background sounds and themes all keep working.

## What you need

- An Apple Silicon Mac with macOS 14 or later
- The Xcode Command Line Tools (the install script offers to install them)
- **Study Timer** itself, from the [Releases](https://github.com/wl3512-lab/study-timer/releases) page, version 2.1 or later

## Install

1. Unzip **StudyTimer-Vorssaint-Island.zip**.
2. Open Terminal and run:
   ```bash
   cd ~/Downloads/StudyTimer-Vorssaint-Island
   ./install.sh
   ```
   (Change the first line if you unzipped it somewhere else.)
3. The script downloads Vorssaint's source to `~/vorssaint-utils`, adds the Study Timer patch, and builds **Vorssaint Developer**, a separate app with its own settings. Your regular Vorssaint isn't changed. Running it again updates an earlier version of the patch.
4. Quit your regular Vorssaint, open **Vorssaint Developer**, and turn on **Dynamic Island** (and its **Timer**).
5. Open the island and go to the **Study** page. You can reorder or hide it in Vorssaint's Dynamic Island settings, like any other page.

To remove it, quit Vorssaint Developer and delete it from Applications, then open your regular Vorssaint again.

## Good to know

- This is a personal build. It doesn't get Vorssaint's official updates. To update, pull the latest Vorssaint and apply the patch again. If the patch no longer fits a newer Vorssaint, the script uses the version it was made for.
- Vorssaint is open source under GPL-3.0. The patch adds a Study page, a listener (`NotchStudyTimerBridge.swift`) and a few lines in Vorssaint's timer; no Study Timer code goes into Vorssaint. Vorssaint's name and icon are its trademarks, so share this patch and script, not a built app.
- The Study page's text is English only for now.

## How it works

Study Timer announces its session to other apps on your Mac whenever it changes (start, pause, skip, end, join), whenever another app asks, and when it quits. It sends the session itself, not a countdown every second, so this costs nothing. The patched island works out the current phase using the same schedule Study Timer uses.

| Notification | Direction | userInfo |
| --- | --- | --- |
| `com.braxtonhauw.studytimer.state` | Study Timer → other apps | `active` (Bool), `focus`, `brk`, `rounds` (Int), `startUtc`, `pausedAt` (Double, 0 = running), `code` (String); `quitting` (Bool) when it closes |
| `com.braxtonhauw.studytimer.request` | other apps → Study Timer | none; Study Timer replies with `state` |
| `com.braxtonhauw.studytimer.command` | other apps → Study Timer | `action`: `start` (with `focus`, `brk`, `rounds`), `togglePause`, `skip` or `end` |

Any app can listen for these, so the same session could show in other tools too.
