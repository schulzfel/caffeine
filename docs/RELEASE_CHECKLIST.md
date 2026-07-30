# Caffeine Community Release Checklist

Complete this checklist for every downloadable GitHub community release and
every supported macOS version. Use separate real Intel and Apple silicon Macs.
Automated checks cannot validate native launch, browser quarantine, Gatekeeper
UI, lid sensors, real sleep transitions, private power SPI, or thermal behavior.

Do not publish with an unchecked acceptance item. Record failures and repeat
the complete affected section after a fix.

## Release record

- [ ] Version:
- [ ] Build:
- [ ] Git commit:
- [ ] GitHub Release URL:
- [ ] DMG filename:
- [ ] DMG SHA-256:
- [ ] Build/test date:
- [ ] Tester:
- [ ] Mac model and year:
- [ ] CPU architecture and chip/model:
- [ ] macOS version and build:
- [ ] Previous Caffeine version used for update testing:

## Automated build and packaging gate

On the build Mac:

- [ ] Start from the intended commit and review every local change.
- [ ] Set shell variables `RELEASE_VERSION` and `RELEASE_BUILD` to the release
      record values above.
- [ ] Run `make test`; all Swift tests pass.
- [ ] Run `make check`; the complete ad-hoc app build and validation pass.
- [ ] Run:

  ```sh
  APP_VERSION="$RELEASE_VERSION" BUILD_VERSION="$RELEASE_BUILD" make release
  ```

- [ ] Confirm the version/build pair is new and no previous artifact was
      overwritten.
- [ ] Confirm the pipeline emits
      `Caffeine-<version>-build-<build>-macOS-universal.dmg` and its matching
      `.sha256` file.
- [ ] From the artifact directory, run:

  ```sh
  shasum -a 256 -c \
    Caffeine-<version>-build-<build>-macOS-universal.dmg.sha256
  ```

- [ ] Run:

  ```sh
  APP_VERSION="$RELEASE_VERSION" BUILD_VERSION="$RELEASE_BUILD" make validate-dmg
  ```

- [ ] Run `hdiutil verify` on the final DMG.
- [ ] Confirm the pipeline does not request a Developer ID identity, Team ID,
      notarization profile, Apple timestamp, notarization submission, staple,
      or Gatekeeper acceptance.
- [ ] Confirm release output clearly identifies the artifact as a community
      build with no Developer ID signature or notarization. The signature
      inspection below separately establishes that the app is ad-hoc signed.
- [ ] Confirm GitHub Actions created a signed provenance attestation for the
      DMG and checksum, then verify the downloaded DMG with:

  ```sh
  gh attestation verify \
    Caffeine-<version>-build-<build>-macOS-universal.dmg \
    --repo schulzfel/caffeine \
    --signer-workflow schulzfel/caffeine/.github/workflows/release.yml
  ```
- [ ] Confirm the DMG itself has no Developer ID distribution signature or
      stapled notarization ticket. It is an unsigned container; do not require
      `codesign` verification or `spctl` acceptance for the DMG.

## App, helper, and signature inspection

Inspect the exact app embedded in the final DMG, not only an earlier build
directory.

- [ ] Run `codesign --verify --deep --strict --verbose=4` on `Caffeine.app`.
- [ ] Run `codesign --verify --strict --verbose=4` on
      `Caffeine.app/Contents/MacOS/CaffeineHelper`.
- [ ] Confirm both signatures report `Signature=adhoc`, no Team Identifier, and
      the hardened-runtime `runtime` flag.
- [ ] Confirm neither executable has a dangerous hardened-runtime exception
      such as disabled library validation or allowed DYLD environment
      variables.
- [ ] Confirm both executables contain exactly `arm64` and `x86_64`:

  ```sh
  lipo -archs Caffeine.app/Contents/MacOS/Caffeine
  lipo -archs Caffeine.app/Contents/MacOS/CaffeineHelper
  ```

- [ ] Extract the app's designated requirement:

  ```sh
  codesign --display --requirements - Caffeine.app 2>&1
  ```

- [ ] Confirm it contains exactly two `cdhash H"<40 hex digits>"` terms joined
      by `or`, one for each Universal 2 slice.
- [ ] Extract and confirm the same two-term exact-CDHash form for the embedded
      helper.
- [ ] Confirm the app identifier is `tech.46h.caffeine` and the helper
      identifier is `tech.46h.caffeine.helper`.
- [ ] Confirm the app embeds the signed `CaffeineHelper` binary for exact
      comparison and one unsigned
      `Contents/Resources/Install Caffeine Helper.pkg`, with no loose
      installer, uninstaller, shared shell support, or LaunchDaemon template.
- [ ] Confirm the app bundle contains the project MIT license and Boxicons
      third-party notice shipped with the binary distribution.
- [ ] Confirm the bundle contains no `Contents/Library/LaunchDaemons`
      SMAppService payload.
- [ ] Expand
      `Caffeine.app/Contents/Resources/Install Caffeine Helper.pkg` into a
      temporary directory with `pkgutil --expand-full`.
- [ ] Confirm the flat package is unsigned and contains no app payload; its
      Installer-staged scripts carry only the expected helper, unprepared plist
      template, root-owned uninstaller, and narrowly scoped install logic.
- [ ] Run `bash -n` and ShellCheck over the expanded package scripts.
- [ ] Confirm the package's legacy plist template uses:

  - `Label=tech.46h.caffeine.helper`;
  - absolute `ProgramArguments[0]` at
    `/Library/PrivilegedHelperTools/tech.46h.caffeine.helper`;
  - `MachServices.tech.46h.caffeine.helper=true`;
  - `KeepAlive=true`; and
  - an empty `CAFFEINE_APP_REQUIREMENT` that the root-staged transaction must
    replace with the installed app's exact two-CDHash requirement.

- [ ] Confirm the template has no `BundleProgram`,
      `AssociatedBundleIdentifiers`, `CAFFEINE_TEAM_ID`, `RunAtLoad`, or
      `UserName`.
- [ ] Confirm the helper carried by the package is byte-for-byte identical to
      the helper embedded in the app.

## DMG and GitHub artifact inspection

- [ ] Confirm the DMG is compressed and read-only and mounts without filesystem
      errors.
- [ ] Confirm its only visible items are `Caffeine.app`, the `/Applications`
      shortcut.
- [ ] Confirm the shortcut targets `/Applications`.
- [ ] Confirm the Finder window uses the intended background and icon
      positions.
- [ ] Confirm the background is `1320 × 840` pixels at `144 DPI`, fills the
      `660 × 420`-point content area without clipping, and appears crisp on a
      Retina display.
- [ ] Confirm the mounted app's version and build match the artifact filename
      and release notes.
- [ ] Push the trusted numeric version tag and confirm the GitHub Actions
      workflow creates a draft Release with both the final DMG and its
      `.sha256` file attached. Do not create a separate Release for that tag.
- [ ] Download both uploaded files through a browser and verify the checksum
      again.
- [ ] Confirm the release notes explain that the same-channel checksum detects
      corruption or replacement but does not independently authenticate the
      publisher or a compromised GitHub Release.
- [ ] Confirm the release notes state that the app is free, ad-hoc signed,
      hardened-runtime enabled, not Developer ID signed, and not notarized.
- [ ] Confirm the release notes link to the source, README installation
      instructions, experimental lid warning, and MIT license.
- [ ] Confirm neither the release notes nor documentation says users must build
      from source.
- [ ] Leave the Release as a draft until every remaining acceptance item in
      this checklist is complete.

## Clean-machine Gatekeeper flow

Use a Mac with no prior approval for this exact build. Download through a
browser so normal quarantine metadata is present.

- [ ] Repeat the complete section on Intel and Apple silicon.
- [ ] Verify the downloaded checksum before opening the DMG.
- [ ] Open the DMG normally and drag Caffeine to `/Applications`.
- [ ] Attempt a normal launch of `/Applications/Caffeine.app`.
- [ ] Confirm Gatekeeper blocks the first launch because Apple cannot verify the
      developer. A different warning such as a damaged or modified app is a
      failure.
- [ ] Open **System Settings → Privacy & Security**, use **Open Anyway** for
      Caffeine, authenticate if requested, and confirm **Open**.
- [ ] Confirm Caffeine launches without clearing quarantine and without
      disabling Gatekeeper or SIP.
- [ ] Confirm the approval is scoped to Caffeine and a second launch of the same
      app no longer requires the override.
- [ ] Confirm no test or documentation uses `spctl --master-disable`,
      `csrutil disable`, removal of `com.apple.quarantine` from the DMG or app,
      `xattr -d`, `xattr -r`, or another security bypass.
- [ ] Confirm Activity Monitor reports native execution rather than Rosetta on
      both architectures.
- [ ] Confirm there is no Dock icon or main window and the coffee-bean glyph
      appears in the menu bar.
- [ ] Confirm a normal Finder launch opens the menu under the coffee-bean
      glyph, while a login-item launch stays unobtrusive.
- [ ] With Caffeine already running, open the app again from Finder and confirm
      its existing menu opens instead of appearing to do nothing.
- [ ] Confirm running from outside `/Applications` provides a clear move-to-
      Applications message for features that require a stable installation.

## Menu, persistence, and ordinary assertions

Perform these checks before installing the optional root helper.

- [ ] Confirm no Caffeine helper or plist exists under
      `/Library/PrivilegedHelperTools` or `/Library/LaunchDaemons`.
- [ ] Toggle **Keep Mac Awake (Display Can Sleep)** alone; its checkmark and
      filled-bean icon update.
- [ ] Toggle **Keep Display On** alone; its checkmark and filled-bean icon
      update.
- [ ] Toggle **Prevent Screen Saver** alone; its checkmark and icon update.
- [ ] Enable all three ordinary options together, then disable each
      independently.
- [ ] With no ordinary option selected, test short display-sleep, screen-saver,
      and system-sleep timers; normal macOS behavior remains.
- [ ] Test **Keep Mac Awake (Display Can Sleep)** only with short display- and
      system-sleep timers; the display turns off normally while the Mac and an
      observable task remain awake.
- [ ] While that option is selected, explicitly choose **Sleep** and confirm
      macOS still sleeps.
- [ ] Test **Keep Display On** only; the display remains lit.
- [ ] Test **Prevent Screen Saver** only; the screen saver does not start.
      Record that a periodic user-activity declaration can also power on the
      display or postpone display sleep.
- [ ] Test all three ordinary options together; the Mac remains awake, the
      display remains lit, and the screen saver does not start.
- [ ] Disable all three and verify normal behavior returns.
- [ ] Inspect `pmset -g assertions` while each option is on and after it is off;
      Caffeine assertions appear and disappear.
- [ ] Quit and relaunch with options selected; persisted selections restore.
- [ ] Confirm menu copy, helper-install guidance, warnings, and artwork are
      legible in light and dark appearances.

## Optional helper install and authentication

First verify the in-app path:

- [ ] Confirm a fresh first-use click opens the embedded macOS Installer flow,
      not Accessibility, Automation, or Login Items settings.
- [ ] Select **Stay Awake When Lid Closed** without an installed helper.
- [ ] Confirm Caffeine explains that installation is optional and
      **Open Installer** prepares its exact embedded package, launches macOS
      Installer, then quits cleanly. The DMG does not need to remain mounted.
- [ ] Confirm the prepared installer uses a canonical UUID-named owner-only
      staging directory, builds a compressed HFS+ image from a complete copied
      app, mounts it read-only/nobrowse/noautoopen, and immediately unlinks the
      writable backing-image path.
- [ ] Confirm Caffeine requires and rechecks the mounted volume's nonempty UUID
      and read-only state, validates the mounted app against the running
      process's exact two-CDHash requirement with all-architecture,
      nested-code, strict-resource, and restricted-symlink checks, and retains
      an open package file descriptor through the LaunchServices handoff.
- [ ] Confirm an ordinary detach is rejected as busy while the package file
      descriptor is retained.
- [ ] Tamper with a test app resource and confirm **Open Installer** fails
      closed, offers the release-specific download page, and does not open
      privileged installer code.
- [ ] Confirm the flow never copies or asks the user to run a `sudo` command.
- [ ] If Gatekeeper blocks the unsigned package on first open, use only the
      per-package **Privacy & Security → Open Anyway** flow.
- [ ] Confirm macOS Installer, not Caffeine, presents the administrator
      authentication UI.
- [ ] Confirm package preflight refuses an app outside the fixed
      `/Applications` path, a running app, or any app whose Universal 2
      architecture, ad-hoc signature, hardened runtime, identifier, bundle
      structure, or embedded helper differs from the package.
- [ ] Confirm the root-staged plist receives the installed app's exact current
      two-CDHash requirement and the app/package are rechecked immediately
      before any privileged mutation.
- [ ] Confirm the package succeeds and starts
      `system/tech.46h.caffeine.helper`.
- [ ] Confirm a successful install relaunches Caffeine as the logged-in user,
      not root, without stealing focus from Installer.
- [ ] Confirm the original lid-mode request becomes active in the relaunched
      app without another click.
- [ ] Cancel before authentication and exercise an induced installer failure;
      confirm neither path relaunches Caffeine.
- [ ] Confirm the installed files are exactly:

  ```text
  /Library/PrivilegedHelperTools/tech.46h.caffeine.helper
  /Library/PrivilegedHelperTools/tech.46h.caffeine.uninstall-helper
  /Library/LaunchDaemons/tech.46h.caffeine.helper.plist
  ```

- [ ] Confirm the helper and uninstaller are `root:wheel` mode `0755`, the
      plist is `root:wheel` mode `0644`, and none is a symlink.
- [ ] Confirm the helper has no setuid bit and runs as root only through
      launchd.
- [ ] Confirm the installed plist contains the exact current app's complete
      two-CDHash Universal designated requirement.
- [ ] Confirm the installed helper's designated requirement exactly matches the
      helper embedded in `/Applications/Caffeine.app`.
- [ ] Select the lid option and rerun the same embedded package without
      changing the app; confirm the operation is safe and the final service
      remains healthy.
- [ ] Confirm the automatically relaunched Caffeine recognizes the installed
      helper.
- [ ] Replace the app temporarily with a different valid ad-hoc build or test
      fixture; confirm the existing helper rejects it until the installer
      rotates the pin. Restore the release build afterward.
- [ ] If the helper is disabled through **Login Items & Extensions**, confirm
      Caffeine turns off lid mode, labels the helper as disabled, and opens
      Login Items on click. Confirm it recovers after the helper is re-enabled.

## Experimental lid and sleep behavior

Perform this section on a hard, ventilated surface. Never place the Mac in a
bag or enclosed space. Keep a remote SSH session, continuous ping, or
long-running observable task available to distinguish awake from asleep.

- [ ] Confirm the UI and README describe lid mode as experimental private SPI,
      not a supported Apple API.
- [ ] Begin with no Caffeine ownership marker and a known `disablesleep` state.
- [ ] On AC power, enable **Stay Awake When Lid Closed**, close the lid, and
      verify the Mac remains reachable and the observable task continues.
- [ ] Reopen the lid, disable the option, close the lid again, and verify normal
      sleep returns.
- [ ] Repeat on battery while monitoring charge and temperature.
- [ ] After disabling, run `pmset sleepnow` and verify the Mac can sleep.
- [ ] Confirm cleanup restores the exact pre-Caffeine value when it began as
      false.
- [ ] Set an intentional true prior value, enable and disable Caffeine, and
      confirm cleanup restores true; immediately return the test machine to its
      intended setting.
- [ ] Confirm helper startup with no valid Caffeine marker leaves an unrelated
      administrator-set value untouched.
- [ ] Record the last-writer limitation: while Caffeine owns the global Boolean,
      another tool can change it, but cleanup restores Caffeine's recorded
      prior value. Do not use competing tools in normal operation.
- [ ] Observe temperature, fan behavior where applicable, CPU use, and battery
      drain; no unexplained runaway behavior occurs.
- [ ] Repeat the complete experiment after each supported macOS update. A
      private-SPI failure must be reported cleanly without breaking the ordinary
      options.

## Crash, kill, and restart recovery

- [ ] Enable lid-closed mode and confirm
      `/var/db/tech.46h.caffeine/SleepDisabledOwned` is `root:wheel`, mode
      `0600`, in a root-only `0700` directory.
- [ ] Record the helper PID and force-terminate it with
      `sudo kill -9 <pid>`.
- [ ] Confirm launchd starts a new helper and startup restores the marker's
      recorded prior value before accepting another authenticated request.
- [ ] Confirm the stale marker is removed before a later request creates a new
      one.
- [ ] Enable lid mode, force-terminate the app, and confirm XPC connection loss
      restores the recorded prior value.
- [ ] Confirm the app reports the lost connection and can reconnect safely.
- [ ] Reboot after exercising lid mode; verify the Mac starts normally and no
      stale Caffeine-owned sleep state remains.
- [ ] With **Launch at Login** enabled and all four options selected, reboot
      and confirm Caffeine launches once, the menu checkmarks return, and every
      selected effect is reapplied after login.
- [ ] Turn **Launch at Login** off, reboot, and confirm the root helper safely
      starts without applying user intent; opening Caffeine manually then
      restores the saved selections.

## Update and CDHash rotation

Begin with the previous community release installed, Gatekeeper-approved, and
using its installed helper.

- [ ] Disable lid mode and quit the previous app.
- [ ] Download and verify the new release, then replace the app in
      `/Applications`.
- [ ] Before reinstalling the helper, confirm the old root-owned plist still
      pins the previous app's CDHashes.
- [ ] Attempt a normal launch of the new app. Complete the per-app
      **Open Anyway** flow if macOS requests it, then confirm the app launches.
- [ ] Confirm the approved new app treats the old helper installation as
      mismatched and does not enable lid mode. The three ordinary options must
      remain usable.
- [ ] In the new app, select the lid option and choose **Open Installer**;
      confirm the app verifies/prepares its embedded package and quits before
      Installer runs it.
- [ ] Confirm the installer boots out the previous service, atomically installs
      the new helper and plist, and reaches a healthy running state.
- [ ] Confirm the plist now pins both CDHashes from the new Universal app and
      the installed helper matches the new embedded helper.
- [ ] Confirm the new app relaunches automatically and verify all four
      options.
- [ ] Exercise an induced installer failure and confirm rollback preserves or
      restores the complete prior helper installation rather than leaving one
      file updated.
- [ ] Confirm release notes and README explicitly tell helper users to rerun the
      installer after every update.

## Launch at login

- [ ] Enable **Launch at Login**, log out and back in, and confirm Caffeine
      launches once with no Dock icon or window.
- [ ] Confirm Gatekeeper approval is not bypassed by launch at login.
- [ ] Disable **Launch at Login**, log out and back in, and confirm Caffeine does
      not launch.
- [ ] If macOS approval is required or later revoked, confirm the menu reflects
      the system state accurately.

## Safe helper and app removal

With the helper installed:

- [ ] Turn off all keep-awake options and verify normal sleep is possible.
- [ ] Turn off **Launch at Login** and quit Caffeine.
- [ ] Run:

  ```sh
  sudo /bin/bash \
    "/Library/PrivilegedHelperTools/tech.46h.caffeine.uninstall-helper"
  ```

- [ ] Confirm the invoked cleanup script is the fixed root-owned `0755` file
      installed by the package, not a file inside the user-writable app.
- [ ] Confirm the uninstaller restores any valid Caffeine-owned marker before
      deleting the recovery executable.
- [ ] Confirm launchd no longer contains
      `system/tech.46h.caffeine.helper`.
- [ ] Confirm the helper, plist, and root-owned uninstaller are absent; the
      uninstaller removes itself last.
- [ ] Confirm `SleepDisabledOwned` is absent. An empty root-owned
      `/var/db/tech.46h.caffeine` directory may remain.
- [ ] Confirm running the uninstaller when the helper is already absent is safe.
- [ ] Move Caffeine to the Trash and reboot.
- [ ] Confirm Caffeine and CaffeineHelper do not run after reboot.
- [ ] Confirm documentation tells users to run the uninstaller before deleting
      the app and never recommends manually deleting a live helper.

## Documentation and release sign-off

- [ ] README download instructions point to GitHub Releases and do not require a
      source build.
- [ ] Gatekeeper instructions describe only the scoped **Open Anyway** flows
      for the app and optional package.
- [ ] Optional helper install/update instructions name the package embedded in
      the release app, and the uninstall command names the fixed root-owned
      cleanup script installed by that package.
- [ ] Documentation explains ad-hoc signing, hardened runtime, lack of Developer
      ID/notarization, exact Universal CDHash pinning, and update rotation
      without implying Apple endorsement.
- [ ] Documentation states that an active same-UID process can force-unmount
      and race-replace an unsigned Installer pathname, puts that interference
      outside the threat model, and warns users not to authorize on a machine
      suspected to be compromised.
- [ ] Experimental private SPI, thermal risk, battery risk, and global-setting
      last-writer behavior are prominent.
- [ ] The repository includes the MIT license naming Caffeine contributors.
- [ ] No blocker, crash, data-loss, privilege-boundary, stale sleep-state,
      Gatekeeper, or thermal-safety issue remains.
- [ ] Product owner:
- [ ] Engineering:
- [ ] QA:
- [ ] Publish the already-validated draft Release; do not rebuild or replace
      its accepted artifacts during publication.
- [ ] GitHub Release published at:
