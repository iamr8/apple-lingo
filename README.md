# AppleLingo

**Subtitles in your language for the Apple TV app on Mac.**

[![CI](https://github.com/iamr8/apple-lingo/actions/workflows/ci.yml/badge.svg)](https://github.com/iamr8/apple-lingo/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/iamr8/apple-lingo)](https://github.com/iamr8/apple-lingo/releases/latest)
[![License: PolyForm Noncommercial](https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue)](LICENSE.md)

The Apple TV app has subtitles in only some languages. AppleLingo adds the missing ones. It translates Apple's own subtitles into your language and shows them over the video. They look just like Apple's subtitles and stay in time with the video.

<!-- TODO: add a screenshot of a scene with translated subtitles -->

## Features

- **Your language on every title** - Persian, or any language Apple does not offer.
- **Good translations** - an AI model translates Apple's subtitles. A second Apple language can help it understand each scene.
- **Looks like Apple's subtitles** - it uses the subtitle style you set in System Settings.
- **Stays in time** - it follows play, pause, skip and seek in the TV app.
- **Set it once** - choose your languages one time. Every new title uses them.
- **Your own subtitle files** - import an `.srt`, `.vtt` or `.ass` file, or a link to one.
- **Quick timing fixes** - move subtitles earlier or later with your own keyboard shortcuts.

## What you need

- A Mac with Apple silicon (M1 or newer)
- macOS 15 (Sequoia) or later
- The Apple TV app
- An API key from [Google Gemini](https://aistudio.google.com/apikey) or [OpenAI](https://platform.openai.com/api-keys). The AI provider may charge for translations.

## Install

1. Download the newest `AppleLingo-….zip` from the [Releases page](https://github.com/iamr8/apple-lingo/releases/latest).
2. Double-click the zip to unzip it.
3. Drag **AppleLingo** into your **Applications** folder.
4. Open AppleLingo.

### The first time you open it

The app is not notarized by Apple, so macOS blocks it the first time. Right-click → **Open** no longer works on macOS 15. Do this instead:

1. Open AppleLingo. A warning says Apple cannot check it. Click **Done**.
2. Open **System Settings** → **Privacy & Security**.
3. Scroll down to **Security**. Next to "AppleLingo was blocked", click **Open Anyway**.
4. Enter your Mac password, then click **Open Anyway** again.

You do this only once. After that, AppleLingo opens like any other app.

> [!NOTE]
> When AppleLingo asks to send notifications, click **Allow**. It uses them to tell you when subtitles are ready or need your help.

## Set up

AppleLingo lives in the menu bar. Look for the speech-bubble icon at the top of your screen. Click it and choose **Settings…**.

1. **Providers** tab: choose Gemini or OpenAI. Paste your API key and click **Authenticate**.
2. **General** tab, under **Languages**:
   - **Target**: the language you want to read.
   - **Secondary** (optional): another language Apple offers, such as Arabic or French. It helps the translation. A language close to yours works best.

## Use it

1. In the TV app, find a movie or episode.
2. Press **Download** on it, then cancel the download. AppleLingo saves Apple's subtitles in that moment.
3. AppleLingo translates them. A notification tells you when they are ready.
4. Play the title. Your subtitles show over the video.

If the title already has subtitles in your language, AppleLingo tells you and does nothing.

### Menu bar options

| Option | What it does |
| --- | --- |
| **Import Subtitle…** | Use your own subtitle file or a link to one. |
| **Reset Offset** | Undo your timing fixes for this title. |
| **Retry Translation** | Try again after a failed translation. |
| **Settings…** | Languages, keyboard shortcuts, AI provider and saved translations. |

### Fix the timing

If subtitles show too early or too late, set keyboard shortcuts in **Settings → General → Timing**. Each press moves them by 0.1 or 0.5 seconds. **Position** shortcuts move them up or down on the screen.

### Change the look

AppleLingo uses your Mac's subtitle style. To change it, open **System Settings → Accessibility → Captions**.

## Questions

**Is my data safe?** Your API key stays in your Mac's keychain. Subtitle text goes only to the AI provider you chose.

**Where are my translations?** In **Settings → Translations**. You can delete them there.

**Does it work with other video apps?** No. It works only with the Apple TV app on Mac.

## License

Free for personal and other noncommercial use. Commercial use is not allowed. See [LICENSE.md](LICENSE.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
