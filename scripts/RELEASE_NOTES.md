Sonar — a native macOS Winamp-style music player. **Beta build.**

## What's new in 0.5.0

- **Karaoke lyrics.** The active lyric line now fills in word by word as it's
  sung (Enhanced LRC). Plain line-synced lyrics still light the whole line.
- **Word-by-word sync through ElevenLabs.** Paste an ElevenLabs API key in
  Settings (kept in the Keychain) and the lyrics panel can turn line-synced
  lyrics into karaoke — or, if a song has no lyrics anywhere, transcribe it
  and time every word from scratch.
  - A **Words / Letters** switch lights either whole words or each letter at
    its real sung time.
  - Long tracks (over 15 minutes) ask first and show the cost; a sync can be
    cancelled at any point, and multi-hour files no longer eat memory.
- **Lyrics for mixes.** In a chaptered file (a DJ set, a compilation) each
  chapter gets its own lyrics, swapped as playback crosses into it and
  prefetched just before.
- **Add lyrics by hand.** When the lookup finds nothing — or the wrong song —
  paste a link (raw .lrc, an LRCLIB record, any lyrics page) or pick a file.
  Found lyrics get a hover-only *"Wrong lyrics?"* to replace them.
- **New library view picker.** The view icon slides out a strip on hover:
  ♥ favorites filter, then Manual / Recent / A–Z / Artist.
- **Two-column layout whenever it fits**, not only in fullscreen.
- **Menu-bar icon** has a right-click Show / Quit menu.
- **Darker app icon** — the equalizer bars now sit on a near-black tile with
  a light bevel.
- **Fixes**
  - Seeking with a trackpad flick commits the moment your fingers lift,
    instead of waiting 2–3 s for the momentum to die out.
  - The seek bar's hover label shows just the time and stays over the bar.
  - Text fields no longer jump on focus, and ⌘A in a text field selects its
    text instead of every track.

## Install

1. Download **`Sonar-<version>.zip`** below and unzip it.
2. Drag **`Sonar.app`** into your **Applications** folder.

## First launch (important)

This is a free beta, so it isn't notarized by Apple. macOS will refuse to open
it on a plain double-click the first time. This is expected — you only do this
once.

**Fastest fix (Terminal):**

```
xattr -cr /Applications/Sonar.app
```

This clears the quarantine flag Gatekeeper adds to downloaded apps. After
running it, Sonar opens normally on double-click — no dialogs.

**Without Terminal:**

On recent macOS (Sequoia/Tahoe), double-clicking shows a dialog that says
Apple couldn't verify the app, with only **Done** / **Move to Bin** — no
"Open Anyway" button here.

1. Click **Done** (not Move to Bin).
2. Go to **System Settings → Privacy & Security**, scroll down to the
   Security section — you'll see **"Sonar" was blocked...** with an
   **Open Anyway** button.
3. Click **Open Anyway**, confirm with your password/Touch ID.
4. Open Sonar again — a second dialog appears, this time with an **Open**
   button.

After that first time, Sonar opens normally like any other app.

## Requirements

- macOS 14 (Sonoma) or later.
