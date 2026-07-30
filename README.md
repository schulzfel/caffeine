# Caffeine

Caffeine is a small native macOS menu bar app that keeps your Mac available
when you need it. It can keep the Mac awake while allowing its display to
sleep, keep the display on, prevent the screen saver, and, with an optional
administrator-installed helper, experimentally keep a Mac notebook awake while
its lid is closed.

Caffeine supports macOS 14 and later and ships as a Universal 2 app with native
Apple silicon and Intel code. It has no Dock icon, main window, analytics,
advertising, or network service.

## Download and install

Download the latest DMG and matching `.sha256` file from the repository's
[Releases page](../../releases/latest). You do not need to build Caffeine from
source.

1. Optionally verify the download from Terminal while in the directory that
   contains both downloaded files:

   ```sh
   shasum -a 256 -c Caffeine-<version>-build-<build>-macOS-universal.dmg.sha256
   ```

2. Open the DMG and drag **Caffeine** onto the **Applications** shortcut.
3. Eject the DMG, then open `/Applications/Caffeine.app`.

The checksum detects an incomplete or changed download, but it is published
through the same GitHub Release as the DMG. It does not independently
authenticate the publisher or protect against a compromised release channel.

Each GitHub Actions release also receives signed GitHub/Sigstore build
provenance. If you have GitHub CLI, verify that the downloaded DMG was produced
by this repository's release workflow:

```sh
gh attestation verify \
  Caffeine-<version>-build-<build>-macOS-universal.dmg \
  --repo schulzfel/caffeine \
  --signer-workflow schulzfel/caffeine/.github/workflows/release.yml
```

Caffeine is a free community release. The DMG itself is unsigned. The app
inside is ad-hoc signed with the hardened runtime, but it is not signed with an
Apple Developer ID and is not notarized by Apple. The first normal launch is
therefore expected to be blocked by Gatekeeper.

After the blocked launch:

1. Open **System Settings → Privacy & Security**.
2. Find the message about Caffeine in the **Security** section and click
   **Open Anyway**.
3. Authenticate to macOS if requested, then confirm **Open**.

The exact wording varies by macOS version. This is a one-time exception scoped
to that Caffeine app, not a global Gatekeeper change. A later Caffeine release
has different code and macOS may require the same per-app approval again.
Organization-managed Macs may prevent local overrides; ask the administrator
rather than weakening system security.

Do not disable Gatekeeper or System Integrity Protection, and do not remove the
`com.apple.quarantine` attribute from the DMG or app. Caffeine never requires
`spctl --master-disable`, `csrutil disable`, `xattr -d`, `xattr -r`, or another
security bypass.

Keep Caffeine in the system `/Applications` folder. Launch at login and the
optional privileged helper both rely on that stable location.

## Menu options

- **Keep Mac Awake (Display Can Sleep)** prevents idle system sleep while still
  allowing the display to turn off normally. It does not override an explicit
  sleep command, closing a notebook's lid, or macOS low-battery safeguards.
- **Keep Display On** holds a macOS power assertion while selected.
- **Prevent Screen Saver** declares user activity approximately every
  30 seconds. This can also wake the display or postpone display sleep because
  that is how the macOS API behaves.
- **Stay Awake When Lid Closed** uses the optional root helper and experimental
  private power-management SPI described below.
- **Launch at Login** uses macOS Service Management for the main app.

The four keep-awake controls are independently selectable. **Enable All**
turns them all on; while any option is active, the command becomes
**Disable All**. Selected state is restored when Caffeine launches again.
Enable **Launch at Login** to restore those selections automatically after a
restart; otherwise they return the next time you open Caffeine manually.

Preventing the screen saver can delay automatic screen locking. Lock the Mac
manually before leaving it unattended.

## Optional lid-closed helper

The three ordinary keep-awake options do not need administrator access. Install
the root helper only if you want to try **Stay Awake When Lid Closed**.

The matching installer is sealed inside each Caffeine app:

1. Select **Stay Awake When Lid Closed**.
2. Review the explanation and choose **Open Installer**.
3. Caffeine prepares and verifies a private read-only installer image, opens
   its exact embedded package in macOS Installer, and quits.
4. Follow macOS Installer and authenticate when it asks.
5. After a successful installation, Caffeine reopens in the menu bar and
   completes the lid-mode request. A cancelled or failed installation does not
   relaunch the app.

If Gatekeeper separately blocks the unidentified package, use the same
**System Settings → Privacy & Security → Open Anyway** flow described above,
then select the lid option again. No Terminal or `sudo` command is part of the
downloaded-app workflow.

### Why this uses macOS Installer

There is no Accessibility, Automation, or other app-privacy permission that
grants an ordinary process the ability to change the private system-wide
lid-sleep setting. Apple's standard Login Items approval experience is
available to bundled `SMAppService` LaunchDaemons, but Apple requires apps
containing those daemons to be notarized. This community build is deliberately
neither Developer ID signed nor notarized, so it cannot reliably use that
registration path.

macOS Installer is therefore the initial authorization UI for the unsigned
community release. It displays the package, requests an administrator's
approval, and stages the privileged scripts itself. Legacy LaunchDaemons
installed into `/Library/LaunchDaemons` are authorized by that protected
administrator write; they do not receive a second, separate Privacy permission
prompt. If the helper is later disabled in **Login Items & Extensions**,
Caffeine opens that System Settings pane directly, and every later click
reopens the actionable pane.

Before opening Installer, Caffeine copies its complete bundle into an
unpredictable owner-only staging directory, creates a compressed private disk
image, mounts that image read-only and hidden from Finder, then unlinks the
writable backing-image path. It validates the mounted volume's stable UUID and
read-only state and validates every architecture, nested executable, sealed
resource, and symlink against the exact running app requirement. It opens and
retains a file descriptor for the mounted package and rechecks the volume and
app before handing the path to Installer. This blocks backing-file writes,
passive package substitution, and ordinary unmounts during the handoff.

After administrator approval, the package independently refuses to change the
system unless `/Applications/Caffeine.app` is quit, Universal 2, validly
ad-hoc signed, and contains the exact packaged helper. It derives the app's
two-architecture CDHash requirement inside root-only staging, prepares the
LaunchDaemon plist there, and rechecks the app and package immediately before
the transactional install:

```text
/Library/PrivilegedHelperTools/tech.46h.caffeine.helper
/Library/PrivilegedHelperTools/tech.46h.caffeine.uninstall-helper
/Library/LaunchDaemons/tech.46h.caffeine.helper.plist
```

All three files are root-owned and not writable by ordinary users. Neither
executable has a setuid bit. The helper exposes one narrow XPC operation:
change Caffeine's `SleepDisabled` ownership request.

### Why the helper must be reinstalled after updates

Ad-hoc signing seals code but does not provide a stable publisher identity.
Caffeine therefore authenticates exact code versions:

- the root-owned daemon plist pins the complete Universal 2 designated
  requirement of `/Applications/Caffeine.app`, containing the exact CDHash for
  each architecture;
- the app accepts only a root helper whose designated requirement matches the
  helper embedded in that same app build; and
- the helper rejects a process with merely the same bundle identifier or a
  different Caffeine build.

Any rebuild whose signed contents differ may change at least one CDHash. Treat
every app replacement or update as a new helper trust boundary: quit Caffeine
and select **Stay Awake When Lid Closed** in that new app to run its sealed
installer. The package safely replaces the helper and rotates the pinned app
requirement. Until then, the ordinary keep-awake options continue to work, but
lid-closed mode reports that the helper needs installation.

If macOS later shows the helper as disabled under **System Settings → General →
Login Items & Extensions**, re-enable it there before using lid-closed mode.

## Updating

1. Turn off **Stay Awake When Lid Closed** and quit Caffeine.
2. Download and optionally verify the new GitHub Release DMG.
3. Replace `/Applications/Caffeine.app` with the new copy.
4. Open the new app normally. Complete the per-app **Open Anyway** step if
   macOS requests it and confirm the app launches.
5. If you use lid-closed mode, select it and choose **Open Installer** to rotate
   the helper's exact-code trust to this update.
6. After a successful helper installation, Caffeine reopens automatically.

Do not keep using an old installed helper with a new app. The exact-code checks
are designed to reject that mismatch.

## Uninstalling

Before moving the app to the Trash:

1. Turn off all keep-awake options.
2. Turn off **Launch at Login**.
3. Quit Caffeine.
4. If the optional helper was installed, run:

   ```sh
   sudo /bin/bash \
     "/Library/PrivilegedHelperTools/tech.46h.caffeine.uninstall-helper"
   ```

5. Move `/Applications/Caffeine.app` to the Trash.

The package installs this cleanup script as a fixed root-owned file, so an
ordinary user cannot replace it before `sudo` runs it. It boots out the
LaunchDaemon, gives the helper an opportunity to restore Caffeine-owned power
state, removes only Caffeine's known helper and plist paths, then removes itself
last. Do not manually delete a running helper.

The empty root-owned directory `/var/db/tech.46h.caffeine` may remain after a
successful uninstall. It contains no recorded power value once
`SleepDisabledOwned` has been removed.

## Lid-closed mode is experimental

Lid-closed mode uses dynamically resolved, undocumented IOKit functions and the
private `SleepDisabled` power setting. This is not a public application API.
Apple may change or remove it in any macOS update, and behavior can vary by Mac
model, power source, and operating-system version. A successful helper install
does not make this feature Apple-supported.

Keeping a closed Mac awake also changes its normal thermal and battery
behavior:

- Keep it on a hard, ventilated surface.
- Never put it in a sleeve, bag, drawer, or other enclosed space while the
  option is active.
- Turn the option off before travel, storage, macOS updates, or leaving the Mac
  unattended.
- Expect increased battery drain and possible thermal throttling.

Caffeine records the prior global `SleepDisabled` value in a durable root-only
marker before changing it. Toggle-off, quit, loss of the authenticated app
connection, helper shutdown, and marked startup recovery restore that recorded
value. Without Caffeine's marker, helper startup leaves unrelated state alone.

`SleepDisabled` is a single system-wide Boolean. If another administrator tool
changes it while Caffeine owns it, Caffeine cannot identify that later writer;
cleanup restores the value recorded before Caffeine took ownership. Do not run
multiple tools that control `disablesleep` concurrently.

Treat lid-closed mode as an opt-in experiment and verify normal sleep after each
macOS update before relying on it.

## Community security model

The DMG and embedded helper installer package are unsigned containers. The
downloadable app and helper are ad-hoc signed with hardened runtime enabled.
The app's outer signature seals the exact embedded package bytes; the
signatures provide code and resource integrity and support exact CDHash
authentication, but they do not establish an Apple-verified developer
identity. The same-channel checksum is not publisher authentication; use the
GitHub provenance attestation and review the source to the degree appropriate
for your environment before granting Installer approval.

The privileged boundary is intentionally small:

- installation is an explicit macOS Installer action initiated by the app;
- privileged scripts exist only inside the package sealed by the exact app
  resource signature, not as loose root-invoked app resources;
- launchd runs a fixed root-owned executable from
  `/Library/PrivilegedHelperTools`;
- both XPC peers enforce exact code requirements;
- the helper accepts only the Boolean lid-sleep operation; and
- connection loss restores Caffeine-owned persistent state.

An administrator or root process can replace system files and is outside this
boundary. So is malicious code already running as the logged-in user that
actively force-unmounts the private installer image and wins a pathname
replacement race before Installer consumes it. An unsigned pathname-based
package handoff has no Apple-verified package identity with which to close that
last race. Do not authorize the helper installer on a Mac you suspect is
already compromised. A Developer ID-signed and notarized `SMAppService` helper
path avoids this unsigned handoff class.

## Build from source

Building is optional and intended for contributors. Install current Xcode
Command Line Tools, then run:

```sh
make test
make app
make validate
```

`make app` creates `dist/Caffeine.app`. `make check` runs the tests and complete
app build validation together. The build compiles native `arm64` and `x86_64`
slices, joins them as Universal 2, signs the helper and app inside-out with
ad-hoc hardened-runtime signatures, and generates the artwork locally. Before
the outer app signature is applied, the build embeds the matching unsigned
helper package. That outer signature seals the exact package, helper,
installer scripts, artwork, and notices as one versioned unit.

To install a locally built helper, first copy the completed app to
`/Applications`, quit Caffeine, review the local scripts, and run
`make install-helper`. This contributor-only path is not used by downloadable
releases. Use `make uninstall-helper` for local cleanup.

With `RELEASE_VERSION` and `RELEASE_BUILD` set to the desired values, supply
them without editing a plist:

```sh
APP_VERSION="$RELEASE_VERSION" BUILD_VERSION="$RELEASE_BUILD" make app
```

## Create a community release

Pushing a trusted numeric release tag such as `v1.0.0` runs the included GitHub
Actions workflow, builds on macOS, and creates a draft GitHub Release with the
DMG and checksum already attached. Tags must be `v` followed by one to three
dot-separated integers; prerelease suffixes are not accepted. The workflow
uses the GitHub run number as the app build number.

Maintainers can create the same artifacts locally with:

```sh
APP_VERSION="$RELEASE_VERSION" BUILD_VERSION="$RELEASE_BUILD" make release
```

The community release pipeline runs tests, builds and validates the ad-hoc
hardened-runtime Universal 2 app, creates and validates its embedded unsigned
helper package, seals the package in the app, places the app in an unsigned
read-only Finder DMG, validates the complete payload, and emits versioned DMG
and SHA-256 artifacts. The DMG's only visible items are Caffeine and the
Applications shortcut. GitHub also signs a Sigstore provenance attestation for
both artifacts. The pipeline does not require an Apple Developer account,
Developer ID certificate, notarization profile, timestamp service, or
notarization submission.

Complete the real-hardware checklist against the exact draft artifacts before
publishing the draft. Once published, users can download the ready-to-install
DMG directly from GitHub without Xcode or a source build.

Revalidate an existing artifact with:

```sh
APP_VERSION="$RELEASE_VERSION" BUILD_VERSION="$RELEASE_BUILD" make validate-dmg
```

Before publishing, complete the
[real-hardware release checklist](docs/RELEASE_CHECKLIST.md) on both Intel and
Apple silicon hardware.

## License

Caffeine is available under the [MIT License](LICENSE). The supplied coffee
glyphs are from MIT-licensed Boxicons; see
[Third-party notices](THIRD_PARTY_NOTICES.md).
