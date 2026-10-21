# IPA delivery preference

User instruction, confirmed 2026-10-20:

- Build and deliver an **unsigned** device IPA. The user signs it themselves.
- Existing iCloud Drive destination: `Telegram-13.0-未签名-20261020`.
- Keep **one latest IPA only** in that folder. After the new IPA passes verification,
  replace the previous delivery and move obsolete package/checksum/report files to Trash.
  Do not empty Trash or clean unrelated iCloud files.
- Keep a verified local copy in `/Users/a1111/111/tg/build-artifacts`.
- This host denies terminal access to iCloud Drive. Use Finder for copying and cleanup;
  verify that the destination contains the new filename and that iCloud upload completes.

## Build and verify

Use the project's full `//Telegram:Telegram` target and current
`build-input/configuration-repository` (bundle ID `ph.telegra.Telegraph`).
The device build requires provisioning-profile attributes for analysis, but the
`--features=disable_legacy_signing` feature disables the signing actions. Do not use
`--//Telegram:disableProvisioningProfiles` for device builds: rules_apple rejects it.
Do not import signing certificates or run a signing command.

```sh
./build-input/bazel-9.2.0-darwin-arm64 build //Telegram:Telegram \
  -c opt --ios_multi_cpus=arm64 --watchos_cpus=arm64_32 \
  --features=swift.opt_uses_wmo --features=swift.opt_uses_osize \
  --features=dead_strip --objc_enable_binary_stripping \
  --features=disable_legacy_signing --define=buildNumber=BUILD_NUMBER
python3 tools/package_unsigned_ipa.py \
  --source bazel-bin/Telegram/Telegram.ipa \
  --output /ABSOLUTE/LOCAL/DELIVERY/Telegram-BUILD_NUMBER-未签名.ipa \
  --build-number BUILD_NUMBER
```

The packager removes pre-existing/automatic linker signatures and embedded profiles,
checks all Mach-O files, validates bundle IDs, all six extensions, device platform,
architecture, build number and ZIP integrity, and writes a local verification report.
It never signs anything. Always package the current `bazel-bin/Telegram/Telegram.ipa`,
not the potentially stale `Telegram_archive-root` directory.

## Video rewatch validation

```sh
xcrun swiftc submodules/GalleryUI/Sources/VideoRewatchStore.swift \
  submodules/GalleryUI/Tests/VideoRewatchStoreTests.swift -o /tmp/video-rewatch-tests
/tmp/video-rewatch-tests
```

UI placement confirmed 2026-10-20:

- Chat: icon-only Rewatch entrance directly above the lower-left blacklist control.
- Player: one star beside Share in the lower-left toolbar; tap toggles the current
  video bookmark, long press opens Rewatch. No upper-right bookmark/Rewatch controls.
- Hollow/filled star reflects whether the current video is bookmarked.

On a signed device, verify: tap to bookmark/unbookmark; long press opens Rewatch
without toggling; chat entrance aligns above blacklist; controls hide with the player
toolbar; bookmark A, scroll to B, open Rewatch, resume A, return to B;
close the list by button and swipe; remove the last bookmark; restart and resume;
try a missing message; check no overlapping audio and portrait/landscape placement.


## Download speed display validation

Added 2026-10-21: show the current account's combined media download speed in
small text below the mute/unmute title. Refresh about once per second while the
panel is on screen and the app is active; idle reads `↓ 0 KB/s`.

```sh
xcrun swiftc submodules/MediaDownloadSpeed/Sources/DownloadSpeedEstimator.swift \
  submodules/MediaDownloadSpeed/Tests/DownloadSpeedEstimatorTests.swift \
  -o /tmp/tg-download-speed-tests
/tmp/tg-download-speed-tests
```

On a signed device, verify: speed changes during media downloads and returns to zero
when idle; mute/unmute still works; title and speed fit in portrait/landscape and both
themes; returning from the background starts with a fresh speed baseline.


Player header: show the same speed beside the date below the channel/author name.
Reserve room for speed on narrow screens. Hide it with the player toolbar; stop sampling
when the player is off screen, displaying a photo, or the app is inactive.
