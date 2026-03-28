# iMessageWidget

I forget to respond to messages. This widget exists to fix this. Run this to create a prioritized queue of messages. Instead of scrolling through threads, you get a compact widget that ranks conversations by urgency and lets you reply without opening Messages.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

---

## How it works

iMessageWidget reads your local `chat.db` (the same database the Messages app uses) and tracks messages you haven't replied to. Each conversation is scored continuously based on:

- **Time decay** — the longer a message sits unanswered, the higher its urgency score (up to 2 weeks)
- **Content signals** — questions, time-sensitive language, emotional content, and long messages all raise the score; conversational closers (like "ok" or "👍") lower it
- **Momentum** — if you were recently going back and forth with someone and dropped the thread, that bumps their score
- **Priority** — a per-contact multiplier you control (1–5), plus a high/low tier setting. High-tier conversations will always be placed above low-tier conversations (default setting is low). 

Conversations are displayed as cards ranked by their effective score (0–100). A color bar on the left of each card shifts from white → orange → red as urgency increases.

---

## Features

- **Priority queue** — conversations sorted by score, so the most overdue replies float to the top
- **Recent view** — switch to chronological order with a single tap
- **Inline reply** — expand any card, type a reply, and send it without leaving the widget
- **Contact settings** — tap a contact's name to open a popover where you can:
  - Toggle **High Tier** to pin them to the top of the queue
  - Set **Priority** (1–5) to weight their score
  - **Snooze** for 2 hours
  - Mark **No reply needed** to permanently dismiss the card
  - **Remove from widget** entirely
- **Auto-dismiss** — cards disappear automatically when you reply from any device, or when Messages marks the thread as read
- **Menu bar icon** — lives in your menu bar; click to show the widget or quit

---

## Requirements

- macOS 14 or later
- Xcode (for building from source)
- **Full Disk Access** — required to read `chat.db`. Granted in System Settings → Privacy & Security → Full Disk Access.

---

## Building and running

```bash
# Build, bundle, sign (ad-hoc), and launch
make run

# Build, sign, and install to /Applications
make install

# Clean build artifacts
make clean
```

The `Makefile` uses Xcode's Swift toolchain. Make sure Xcode is installed at `/Applications/Xcode.app`.

---

## First launch

On first launch, a setup window walks you through three steps:

1. **Full Disk Access** — the app opens System Settings for you and polls until access is granted
2. **Contacts Access** — optional, but allows the widget to show names instead of phone numbers
3. **Initial analysis** — scans your message history for unanswered threads

After setup, the widget appears and the setup window won't show again.

---

## Scoring reference

| Component | Range | Notes |
|---|---|---|
| Time score | 0–50 | Logarithmic; maxes out at 2 weeks |
| Content score | 0–20 | Based on questions, urgency, emotion, message length |
| Momentum score | 0–5 | Recent back-and-forth that you dropped |
| Priority addend | 0–25 | Derived from per-contact priority (1–5) |
| **Effective score** | **0–100** | Sum of above, capped at 100 |

Cards with a score below 31 show no color bar. 31–60 is amber. 61–100 is red.
