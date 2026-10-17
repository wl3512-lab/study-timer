# Study Timer

A study timer you can share with a friend using a short code. No accounts, no server: each device computes the same countdown from its own clock, so you both stay in sync even if one of you joins late.

## Two ways to use it

**Web timer** (`study_timer.html`): set focus minutes, break minutes, rounds and a start time, click **Start**, then **Copy** the share code and send it to your partner. They paste it into **Join** on their copy of the page.
Live version: https://claude.ai/artifact/JnMKumzc6V92D4AHpx1K9L

**Mac menu bar app** (`menubar/`): shows the countdown in the macOS menu bar. Copy a share code, click the timer icon, and choose **Join Code from Clipboard**. It reads the same codes as the web timer.

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

This builds `menubar/StudyTimerBar.app`, a universal app for macOS 13 and later. Run the tests with:

```bash
./menubar/StudyTimerBar.app/Contents/MacOS/StudyTimerBar --test
```

The app isn't signed with an Apple developer account. The first time you open it, macOS blocks it: go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Tests

The web timer runs its own self-tests on load. Click **Self-check** at the bottom of the page to see each result. Both versions test the same sample codes, so a code made in one always works in the other.
