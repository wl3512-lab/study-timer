# Study Timer

A study timer you can share with a friend using a short code. No accounts, no server: each device computes the same countdown from its own clock, so you both stay in sync even if one of you joins late.

Braxton Hauw wrote the original web timer and a first menu bar app. Lucy Liu built the Aura menu bar redesign on top of it: themes, background sounds, chimes, Spotify, presets and the Vorssaint island.

## Get the Mac app

1. Download **StudyTimerBar.zip** from this repo's [Releases](../../releases) page and unzip it.
2. Drag **StudyTimerBar.app** into your Applications folder and open it.
3. macOS will say it can't check the app for malware, because it isn't signed with a paid Apple developer account. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
4. Allow notifications when it asks. Look for the ring in your menu bar (if your menu bar is crowded, it may be hidden behind the notch).

Needs macOS 13 or later. No Mac? The web timer below uses the same share codes, so you can still study together.

## Two ways to use it

**Web timer** (`study_timer.html`): set focus minutes, break minutes, rounds and a start time, click **Start**, then **Copy** the share code and send it to your partner. They paste it into **Join** on their copy of the page.
Live version: https://claude.ai/artifact/JnMKumzc6V92D4AHpx1K9L

**Mac menu bar app** (`menubar/`): a small ring in the menu bar fills up as the current phase runs, with the countdown beside it. Click it to open the panel:

- **Start a session** from a preset (25/5, 50/10, 90/15) or set focus, break and rounds yourself. The dial at the top shows one round on a two-hour face (four hours for longer rounds): focus in blue from the top, then break in mint. Hover over it or click it and a handle appears at the end of the round; drag anywhere on the ring to stretch the round, and focus and break grow and shrink together (break keeps its share of focus, so 25/5 becomes 50/10). Dragging past the top switches to the four-hour face.
- **While it runs**: a progress ring around the countdown, one dot per round, and a soft aura that breathes behind it. The aura is locked to the session clock (one breath every 6 seconds, quickening to every 2 seconds in the last minute of a phase), so two people on the same code see it breathe in sync.
- **Colors**: in the default Aura theme, light blue for focus, mint for break, lavender while waiting to start, gold when done.
- **Themes** (Settings → Theme): **Aura** (night sky), **Cloud** (light, for daytime), **Mochi** (soft pastels), **Mono** (black and white, menu bar icon matches your menu bar), and **Prism** (an iridescent ring, with an aura whose hue drifts once a minute on the session clock). Themes change colors and the aura; layout and fonts stay the same.
- **Controls**: pause/resume (Space), skip to the next phase (→), end session. Pausing or skipping moves the session's start time, which changes the share code. The panel tells you to send your partner the new one.
- **Presets**: click one to use it, click **+ save** to keep your current focus/break/rounds as a new one (up to 6), right-click to delete.
- **Join a partner**: paste a code, or a whole invite message, or click the clipboard button to join whatever you've copied.
- **Listen together**: Spotify doesn't let other apps start a Jam, so start one in Spotify, copy its link, and click **paste** in the panel. **Copy** then copies your code and the Jam link together, and when your friend joins with that message, their Spotify opens your Jam.
- **Notifications**: silent macOS alerts when focus starts, 1 minute before a break, when a break starts, 1 minute before a break ends, and when the session is done. Your chosen chimes play the sound. The 1-minute warnings skip phases shorter than 3 minutes.
- **Settings** (gear icon, or ⌘,):
  - **Theme**: the five themes below.
  - **Background sound**: white, pink or brown noise, rain, or ocean, made live by the app so it loops with no seams. It fades in during focus and out on breaks (or keeps going, if you turn on "also during breaks"), with its own volume.
  - **Notifications**: turn pop-ups on or off, and turn each alert on or off: focus starts, 1 min before break, break starts, 1 min before break ends, session done. An alert that's off plays no chime either; with pop-ups off, the alerts you keep on still chime.
    Click the pencil next to an alert to make it your own: change its title and message (with fill-in words: {round}, {rounds}, {next}, {focus}, {break}, and {time} for when that part ends), pick a picture that shows on the right of the notification (19 come with the app, from an alien cat and a sleepy cat to boba, books, a rocket and a rainbow cloud, or choose your own), see a live preview, and send a test.
  - **Chimes**: pick a macOS sound (or none) for each alert, plus chime volume. ▶ plays one. Chimes follow your Mac's main volume, not the alert volume.
  - **Menu bar**: show ring + time, ring only, or time only, as 18:42 or 19m.
  - **Spotify**: open Spotify when a session starts, play a playlist or album you paste a link to, and pause the music on breaks. The first time, macOS asks to let Study Timer control Spotify.
  - **Open at login**.

It reads and writes the same codes as the web timer.

**In Vorssaint's notch** (`integrations/vorssaint/`): if you use [Vorssaint](https://github.com/vorssaint/vorssaint-utils), a small patch puts Study Timer in the notch the way Vorssaint shows Codex: a **Study** page in the island with the ring, aura, rounds and controls, a live countdown in the island's strip, and a pop-out notice when a break starts, focus resumes, or the session is done. Starting a Pomodoro on Vorssaint's Timer page runs it in Study Timer. Download **StudyTimer-Vorssaint-Island.zip** from Releases and run its `install.sh`; see [its README](integrations/vorssaint/README.md).

## How a session works

Each round is a focus block followed by a break, except the last round has no break. A 25 / 5 / 4 session runs 25 + 5 + 25 + 5 + 25 + 5 + 25 = 115 minutes.

Small differences between devices come from their clocks. If your countdowns differ, compare the UTC clock shown at the bottom of the web timer.

## Share code format

```
1-p-5-4-tn2co0-3r
│ │ │ │ │      └ checksum
│ │ │ │ └ start time, UTC seconds
│ │ │ └ rounds
│ │ └ break minutes
│ └ focus minutes
└ format version
```

Every field is base36. The checksum is a position-weighted sum of the character codes, mod 1296, written as two base36 characters. It rejects any single mistyped character. Spaces, line breaks and capital letters are ignored when decoding.

Limits: focus 1 to 180 minutes, break 1 to 60, rounds 1 to 12, start between 2020 and 2099.

## Building the menu bar app

Requires Xcode command line tools.

```bash
./menubar/build.sh
```

This builds `menubar/StudyTimerBar.app`, a universal app for macOS 13 and later, with its fonts (Syne, DM Sans and Space Mono from `menubar/fonts/`, all under the SIL Open Font License) bundled inside. Run the tests with:

```bash
./menubar/StudyTimerBar.app/Contents/MacOS/StudyTimerBar --test
```

The app isn't signed with an Apple developer account. The first time you open it, macOS blocks it: go to **System Settings → Privacy & Security** and click **Open Anyway**. Allow notifications when it asks.

## Tests

The web timer runs its own self-tests on load. Click **Self-check** at the bottom of the page to see each result. Both versions test the same sample codes, so a code made in one always works in the other. The menu bar app also tests pausing, skipping, the aura's breathing, Spotify link and invite parsing, and that every background sound is audible, never clips and fades out cleanly.
