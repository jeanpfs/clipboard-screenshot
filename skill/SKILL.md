---
name: screenshots
description: macOS screenshots are copied to the clipboard automatically by clipboard-screenshot. Use when the user mentions a recent screenshot, pasting a capture, or "what I just captured".
---

# Screenshots (clipboard)

`clipboard-screenshot` puts each new screenshot on the system clipboard so the user can `⌘V` right away.

## Behavior

1. User takes `⌘⇧3` / `⌘⇧4`
2. Image is on the clipboard within a moment
3. The file is whatever macOS already saved (location unchanged by this tool)

## Logs

```bash
tail -f ~/Library/Application\ Support/com.stevederico.clipboard-screenshot/watcher.log
```
