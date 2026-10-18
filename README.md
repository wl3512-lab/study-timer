# Study Timer

A study timer you can share with a friend using a short code. No accounts, no server: each device computes the same countdown from its own clock, so you both stay in sync even if one of you joins late.

## Two ways to use it

**Web timer** (`study_timer.html`): set focus minutes, break minutes, rounds and a start time, click **Start**, then **Copy** the share code and send it to your partner. They paste it into **Join** on their copy of the page.
Live version: https://claude.ai/artifact/JnMKumzc6V92D4AHpx1K9L

**Mac menu bar app** (`menubar/`): a small ring in the menu bar fills up as the current phase runs, with the countdown beside it. Click it to open the panel:

- **Start a session** from a preset (25/5, 50/10, 90/15) or set focus, break and rounds yourself. The ring at the top shows one round's focus and break split.
- **While it runs**: a progress ring around the countdown, one dot per round, and a soft aura that breathes behind it. The aura is locked to the session clock (one breath every 6 seconds, quickening to every 2 seconds in the last minute of a phase), so two people on the same code see it breathe in sync.
- **Colors**: in the default Aura theme, light blue for focus, mint for break, lavender while waiting to start, gold when done.
- **Themes** (Settings → Theme): **Aura** (night sky), **Cloud** (light, for daytime), **Mochi** (soft pastels), **Mono** (black and white, menu bar icon matches your menu bar), and **Prism** (an iridescent ring, with an aura whose hue drifts once a minute on the session clock). Themes change colors and the aura; layout and fonts stay the same.
- **Controls**: pause/resume (Space), skip to the next phase (→), end session. Pausing or skipping moves the session's start time, which changes the share code. The panel tells you to send your partner the new one.
- **Presets**: click one to use it, click **+ save** to keep your current focus/break/rounds as a new one (up to 6), right-click to delete.
- **Join a partner**: paste a code, or a whole invite message, or click the clipboard button to join whatever you've copied.
- **Listen together**: Spotify doesn't let other apps start a Jam, so start one in Spotify, copy its link, and click **paste** in the panel. **Copy** then copies your code and the Jam link together, and when your friend joins with that message, their Spotify opens your Jam.
- **Notifications**: silent macOS alerts when focus starts, when a break starts, 1 minute before a break ends, when it's time to focus again, and when the session is done. Your chosen chimes play the sound.
- **Settings** (gear icon, or ⌘,):
  - **Theme**: the five themes below.
  - **Background sound**: white, pink or brown noise, rain, or ocean, made live by the app so it loops with no seams. It fades in during focus and out on breaks (or keeps going, if you turn on "also during breaks"), with its own volume.
  - **Chimes**: pick a macOS sound (or none) for focus starting, break starting, the 1-minute break warning, and session done, plus chime volume.
  - **Menu bar**: show ring + time, ring only, or time only, as 18:42 or 19m.
  - **Spotify**: open Spotify when a session starts, play a playlist or album you paste a link to, and pause the music on breaks. The first time, macOS asks to let Study Timer control Spotify.
  - **Notifications**, the 1-minute warning, and opening at login.

It reads and writes the same codes as the web timer.

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
