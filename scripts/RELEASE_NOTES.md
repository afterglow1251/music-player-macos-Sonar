Sonar — a native macOS Winamp-style music player. **Beta build.**

## What's new in 0.3.0

- **YouTube downloads work again.** YouTube started turning away anonymous
  requests with *"Sign in to confirm you're not a bot"*, which broke every
  download. Sonar now falls back to the cookies of a browser you're already
  signed into, exactly as `yt-dlp` recommends.
- **It picks the browser for you.** Rather than guessing, Sonar checks which
  browser actually holds a signed-in YouTube session and uses the one you've
  used most recently. Chrome, Edge, Brave, Vivaldi, Opera and Firefox are all
  understood.
  - Chromium-based browsers encrypt their cookies, so macOS will ask once for
    permission to read the key — that's the Keychain prompt you'll see. Firefox
    needs no prompt at all.
  - The first attempt is always anonymous, so this only kicks in when YouTube
    insists.
- **Clearer failures.** Download errors now say what went wrong — rate
  limiting, an age-restricted video, a missing tool — instead of pasting
  `yt-dlp`'s raw output into the corner of the window.
- **Missing `ffmpeg` is caught up front**, rather than halfway through a
  download that was never going to finish.

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
