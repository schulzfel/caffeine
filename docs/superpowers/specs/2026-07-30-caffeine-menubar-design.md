# Caffeine — macOS Menu Bar Keep-Awake App

**Date:** 2026-07-30
**Status:** Approved

## Overview

A minimal native macOS menu bar app that keeps the Mac awake. No windows, no
Dock icon — it lives entirely in the menu bar. Four independently combinable
keep-awake options, an enable/disable-all shortcut, launch-at-login, and a
separately installed optional privileged helper for experimental
"stay awake with lid closed" support. The app never collects or handles an
administrator password; users who want the helper explicitly open the
flat installer sealed inside the exact running app.

Target: macOS 14+ (built and tested on macOS 26), Universal 2 with native
`arm64` and `x86_64` slices. Caffeine is a free, open-source community app
distributed as a downloadable GitHub Release DMG. Both slices use identity-free
ad-hoc signatures with the hardened runtime enabled; the app has no Developer
ID identity and is not notarized by Apple.

## Menu bar icon

- The supplied original 24×24 SVG artwork is rendered locally rather than
  derived from an SF Symbol.
- **Active** (any option enabled): the filled glyph used by the application
  icon.
- **Inactive** (all off): the supplied outline glyph.
- Bundled transparent template images adapt automatically to light and dark
  menu bars.

## Application icon

- The supplied filled glyph, rendered near-black on a white rounded-square
  macOS tile.
- The application and active menu-bar artwork use the exact same SVG paths.
- Minimal, high-contrast construction that remains recognizable from 16 to
  1024 pixels.
- Generated deterministically from local Swift drawing code; no downloaded
  artwork or third-party asset dependency.

## Menu structure

```
✓ Keep Mac Awake (Display Can Sleep)
✓ Keep Display On
✓ Prevent Screen Saver
  Stay Awake When Lid Closed
─────────────────────────────
  Enable All            ← title flips to "Disable All" when any option is on
─────────────────────────────
✓ Launch at Login
─────────────────────────────
  Quit Caffeine
```

- The four keep-awake options are independent checkboxes (multi-select).
- "Enable All" turns all four on; when one or more are on it reads
  "Disable All" and turns all four off.
- Option state persists in `UserDefaults` and is restored (and re-applied)
  on launch.

## Option mechanisms

| Option | Mechanism |
|---|---|
| Keep Mac Awake (Display Can Sleep) | `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` — prevents idle system sleep without preventing display sleep; it does not override explicit sleep, lid closure, or low-battery safeguards |
| Keep Display On | `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)` |
| Prevent Screen Saver | Periodic `IOPMAssertionDeclareUserActivity` (every ~30 s while enabled) — declares user activity to reset the screen-saver idle timer; macOS also powers on the display and postpones display sleep, so this control's observable display effect is not independent |
| Stay Awake When Lid Closed | XPC call to the optional privileged root helper, which experimentally uses private IOKit SPI to set the system power setting `SleepDisabled` (equivalent of `pmset disablesleep 1`) |
| Launch at Login | `SMAppService.mainApp.register()` / `.unregister()` |

Notes:

- Assertions are held by the app process and released on toggle-off and on quit.
- Before changing `SleepDisabled`, the helper durably records its prior value.
  Toggle-off, connection loss, quit, and marked startup recovery restore that
  value; startup without Caffeine's marker leaves unrelated state untouched.
- `SleepDisabled` is one global Boolean. If another tool changes it while
  Caffeine owns it, cleanup cannot identify that newer writer and restores the
  recorded pre-Caffeine value. Competing tools must not control it concurrently.
- Each assertion carries a human-readable reason string (shows up in
  `pmset -g assertions`).

## Privileged helper (root daemon)

- A tiny Swift executable bundled at
  `Caffeine.app/Contents/MacOS/CaffeineHelper` so the app can authenticate the
  installed copy. The matching flat installer is stored as one outer-signature-
  sealed app resource; its scripts, uninstaller, and LaunchDaemon template do
  not exist as loose root-invoked resources.
- The helper is not an `SMAppService.daemon`, and the app contains no embedded
  Service Management daemon plist. Installation is an explicit macOS Installer
  action initiated from the lid option.
- The unsigned flat package is generated after the nested helper is signed but
  before the outer app signature. The outer signature therefore seals the
  exact package bytes without a CDHash cycle. Its Installer-staged scripts
  carry the signed helper and an unprepared LaunchDaemon template. After
  administrator approval, the root transaction validates the exact app,
  package helper, signatures, architectures, locations, and system targets;
  derives the running release's exact two Universal CDHashes; prepares the
  plist in root-only staging; and rechecks everything immediately before
  mutation. The package installs
  `/Library/PrivilegedHelperTools/tech.46h.caffeine.helper` and
  `/Library/LaunchDaemons/tech.46h.caffeine.helper.plist` as root-owned files,
  plus a fixed root-owned uninstaller at
  `/Library/PrivilegedHelperTools/tech.46h.caffeine.uninstall-helper`, then
  safely updates and bootstraps the legacy LaunchDaemon with `launchctl`.
- The helper exposes a single XPC protocol:
  `setSleepDisabled(_ disabled: Bool, reply: (Bool) -> Void)`.
  It does nothing else.
- Because an ad-hoc signature has no stable publisher identity, the root-owned
  daemon plist pins the app's complete Universal 2 designated requirement: an
  exact two-term CDHash OR expression containing one CDHash for `arm64` and one
  for `x86_64`. The helper accepts only a caller satisfying that exact
  requirement; a matching bundle identifier alone is never sufficient. The app
  likewise checks that the installed root helper exactly matches the helper
  embedded in the current app.
- Any rebuild or update with changed signed contents changes the pinned hashes.
  Users of lid-closed mode must quit Caffeine and rerun the helper installer
  after every app replacement.
  Until they do, the three ordinary keep-awake options remain available and
  lid-closed mode reports that installation is required.
- The uninstaller is explicit but runs only from its root-owned installed path:

  ```sh
  sudo /bin/bash \
    "/Library/PrivilegedHelperTools/tech.46h.caffeine.uninstall-helper"
  ```

  It starts an installed-but-unloaded helper long enough to repair any marked
  stale `SleepDisabled` state, boots it out, removes the exact helper and plist
  paths, then removes itself last.
- The `SleepDisabled` implementation dynamically resolves undocumented,
  private IOKit SPI. Lid-closed mode is experimental, can vary by Mac model and
  power source, and may stop working after any macOS update.

### Helper installation UX — explicit and optional

The daemon itself has no UI. Users who never select "Stay Awake When Lid
Closed" never need the helper or administrator access.

1. If the user selects the option while the helper is missing or pinned to a
   different app build, Caffeine explains the optional administrator helper and
   offers **Open Installer** or **Not Now**.
2. After **Open Installer**, Caffeine copies its complete bundle into a
   UUID-named owner-only staging directory, builds a compressed private HFS+
   image, mounts it read-only and hidden, and unlinks the writable backing-image
   path. It validates the mounted app against the exact running Universal
   designated requirement with all-architecture, nested-code, strict resource,
   and restricted-symlink checks; requires and rechecks a stable nonempty volume
   UUID and read-only flag; opens and retains the package file descriptor; then
   hands that mounted path to Installer and quits automatically. Failure offers
   the release-specific download page and never opens privileged code. There is
   no onboarding window, custom chrome, or copied root command.
3. macOS Installer performs authentication; Caffeine never sees or stores the
   password.
4. After installation the user reopens Caffeine. If macOS separately disables
   the legacy background item, the option remains off with a quiet approval
   hint and directs the user to Login Items settings.

The unsigned community build cannot substitute an `SMAppService` LaunchDaemon
for this package: Apple's Service Management contract requires apps containing
LaunchDaemons to be notarized. There is no standalone TCC permission for the
private `SleepDisabled` setting.

The private read-only image blocks backing-file writes, passive substitution,
and ordinary unmounts during the handoff. It cannot cryptographically bind an
unsigned package pathname against malicious code already running as the
logged-in user that force-unmounts the volume and wins a replacement race
before Installer consumes it. That active same-UID mount interference is
explicitly outside the community build's threat model; users must not approve
the helper installer on a Mac suspected to be compromised. A Developer
ID-signed and notarized `SMAppService` helper avoids this unsigned handoff.

## App behavior

- `LSUIElement = true` (no Dock icon, no main window).
- Native Swift Package (`swift build`), AppKit `NSStatusItem` + `NSMenu`, no
  storyboards/nibs.
- State model:
  `enum WakeOption { systemAwake, displayOn, screenSaver, lidClosed }` with a
  small controller owning the option set, persistence, and side effects.
- Power layer behind a protocol (`PowerController`) so the IOKit and XPC
  calls are mockable in tests.

## Build & distribution

- `Package.swift` with two executable targets: `Caffeine` (app) and
  `CaffeineHelper` (daemon).
- `Makefile` / script: `make app` → `swift build -c release`, assemble
  `Caffeine.app` bundle (Info.plist, helper, and icons), and sign the helper and
  app explicitly inside-out with
  identity-free ad-hoc signatures and the hardened runtime on both
  architectures.
- `make release` runs tests, builds and validates the Universal 2 app, creates
  the release-specific unsigned helper package inside it before the outer app
  seal, places the app into a read-only drag-to-Applications DMG, validates its
  layout and payload, and emits version-and-build-specific DMG and SHA-256
  artifacts without overwriting an existing release. It does not use a
  Developer ID certificate, Apple timestamp, notarization submission, or
  stapled ticket.
- The DMG and checksum are published as free downloads on GitHub Releases
  alongside the open-source repository, and the release workflow publishes a
  GitHub/Sigstore provenance attestation for both artifacts.
- The DMG presents only `Caffeine.app` and an `/Applications` shortcut in a
  polished Finder window with a locally rendered background and drag direction.
- Install by opening the DMG and dragging to `/Applications`. The stable system
  path is required for launch at login and the optional helper.
- Because the community build is neither Developer ID signed nor notarized,
  Gatekeeper is expected to block its first normal launch. Documentation leads
  the user through System Settings → Privacy & Security → **Open Anyway**. This
  creates a per-app exception only; Caffeine never instructs users to disable
  Gatekeeper or SIP, or to remove quarantine recursively. A changed release may
  require a new per-app approval.
- `SMAppService.mainApp.register()` / `.unregister()` remains the mechanism for
  **Launch at Login**. The root daemon is never installed or registered through
  `SMAppService.daemon`.

## Error handling

- Helper missing or pinned to another app build → lid-closed option stays off
  and the optional installation alert is available.
- Legacy helper disabled by macOS → quiet approval hint and a route to Login
  Items settings.
- XPC connection failure → option reverts to off, hint shown; retried on
  next toggle.
- Assertion creation failure (rare) → option reverts, logged via `os_log`.
- On quit: release all assertions and ask the helper to restore the recorded
  pre-Caffeine `SleepDisabled` value.

## Testing

- `swift test` unit tests: state model transitions, enable/disable-all logic,
  persistence round-trip, menu-state derivation — with a mock
  `PowerController`.
- Packaging validation: both executables contain exactly `arm64` and `x86_64`
  slices, each is ad-hoc signed with the hardened runtime, the bundle has no
  loose root-executed scripts or `SMAppService` daemon payload, the outer app
  signature seals an unsigned package with the matching helper and unprepared
  canonical plist template, and the read-only DMG contains a 2× Retina
  background with a 660-by-420-point logical size and a matching unclipped
  Finder content area.
- Manual smoke tests (real hardware only): idle system sleep is prevented while
  display sleep remains available, display stays on, screensaver is suppressed,
  the Gatekeeper **Open Anyway** flow works, launch-at-login survives reboot,
  the optional helper installs/updates/uninstalls safely, its exact two-CDHash
  pin rejects an old/new app mismatch, lid-close keeps the Mac running, and
  prior sleep state is restored after disable/quit/recovery.
  Repeat the complete launch and helper paths natively on both Intel and Apple
  silicon hardware, including reinstalling the helper after an app update.
- Recheck experimental lid-closed behavior and normal sleep restoration after
  every macOS update; successful behavior on one OS or Mac model is not a
  compatibility guarantee.

## Out of scope (YAGNI)

- Timers/schedules ("keep awake for 1 hour")
- Battery-level safeguards
- Preferences window
- Mac App Store distribution
