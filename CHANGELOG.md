# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Docs
- README demo GIF: the real `⌘⇧4` then `⌘V` flow recorded on macOS, with the scripts that record it in `scripts/demo/`.

## [0.1.0] - 2026-10-15

First release of this fork of [stevederico/clipboard-screenshot](https://github.com/stevederico/clipboard-screenshot) (MIT), with fixes for macOS Sequoia. Credit for the original tool goes to Steve Derico.

### Fixed

- `⌘⇧4` captures are now detected: Sequoia splits the capture-location preference per mode, so the agent reads `location-screenshot` (used by the interactive UI) as well as the legacy `location` key.
- Removed a ~30 s fruitless retry loop that held the lock and made the next screenshot's event get dropped. Discovery is now ordered by cost (directory listing before Spotlight) and the System Events fallback runs once after the loop, bringing the wait down to ~5 s.
- Screenshots taken in the same second as the previous one are no longer dropped: modification times now use nanosecond precision (`stat -f %Fm`).
- A stale Spotlight result from the launchd agent no longer masks the fallbacks.

### Changed

- Only the configured screenshot location is watched; watching `~/Desktop` as well caused unrelated wake-ups and lock contention.
- The support directory is created with mode `700`.
- Uninstall refuses to `rm -rf` a `CLIPBOARD_SCREENSHOT_HOME` outside its own bundle id and restores both location keys.

### Added

- `VERSION` file declaring the release version.
- GitHub Actions workflows for syntax checks and tag-driven releases.

[Unreleased]: https://github.com/jeanpfs/clipboard-screenshot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jeanpfs/clipboard-screenshot/releases/tag/v0.1.0
