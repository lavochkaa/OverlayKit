# OverlayKit

Floating system overlay for TrollStore. A draggable circle that sits on top of all apps — tap it to trigger actions.

## Features

- Round draggable button over all apps
- Pan gesture to reposition anywhere on screen
- Tap to show "injected" label

## Stack

- **UI**: Swift + UIKit / Objective-C
- **Build**: Xcode, iOS 14.0+, arm64

## Requirements

- iPhone/iPad with [TrollStore](https://github.com/opa334/TrollStore) installed
- iOS 14.0+

## Installation

1. Download `OverlayKit.tipa` from [Releases](../../releases)
2. Open with TrollStore
3. Install

## Build

```bash
bash build.sh
```

Requires `ldid` (`brew install ldid`).

## Entitlements

```xml
<key>task_for_pid-allow</key>
<true/>
<key>com.apple.private.security.no-sandbox</key>
<true/>
<key>platform-application</key>
<true/>
<key>com.apple.private.security.no-container</key>
<true/>
```
