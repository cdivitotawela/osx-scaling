# scalectl

A standalone Swift CLI for requesting extra native scaled/HiDPI resolutions on macOS and selecting available display modes. It does not need BetterDisplay running, a virtual display, a background service, or third-party packages.

Requires macOS 13 or later. Native override support and available modes depend on the macOS version, GPU, display, and connection. The override format is undocumented; this is an initial implementation, not a claim of compatibility with every display. Backup/restore and confirmation behavior are checked without changing real display settings.

## Install

Download the `arm64` archive for Apple Silicon, or `x86_64` for Intel, from [Releases](https://github.com/cdivitotawela/osx-scaling/releases). Release archives include `scalectl/bin/scalectl` and this README, plus a separate SHA-256 checksum file. To verify an archive, run `shasum -a 256 -c ARCHIVE.tar.gz.sha256` in its download directory before extracting it. Release binaries are ad-hoc signed, not Apple Developer ID signed or notarized. Initial release assets become available after a version tag is pushed and its workflow succeeds.

Or build from source with Swift 6+ and Apple Command Line Tools:

```sh
git clone https://github.com/cdivitotawela/osx-scaling.git
cd osx-scaling
./scripts/build.sh
```

The build creates `bin/scalectl` for the current Mac's architecture. It does not install anything system-wide.

## Start here

Open Terminal in the source folder after building, or in the `scalectl` folder extracted from a release:

```sh
./bin/scalectl displays
./bin/scalectl show
./bin/scalectl modes --display DISPLAY_UUID
```

Replace `DISPLAY_UUID` with the UUID printed by `displays`. Numeric display IDs also work, but can change after reconnecting. `displays` and `modes` accept `--json` for scripting.

`show` displays the current configuration for every online display: mode ID, logical desktop resolution, rendering pixels, approximate rendering scale, HiDPI/LoDPI, reported refresh rate, rotation, position, and display identity. Use `show --display DISPLAY_UUID` to select one display, or `show --json` for structured output (an array, even for one display). Rendering scale is rendering pixels divided by logical dimensions; it is not a percentage relative to the physical panel or the default desktop size. The refresh rate is the value reported by the current mode, rather than a live VRR measurement.

The mode list distinguishes desktop size (“looks like”) from rendering pixels. A HiDPI mode usually renders at twice the logical width and height; the compositor fits that to the actual panel. Scaling cannot add physical pixels or exceed the GPU's limits. Fractional downsampling can still soften the image.

## Add selectable resolutions

First preview the requested sizes. This reads existing configuration and does not write any system files:

```sh
./bin/scalectl add --display DISPLAY_UUID --sizes 1600x900,1920x1080,2048x1152
```

Those examples have a 16:9 aspect ratio. Choose sizes matching your own display; mismatched ratios may be rejected or produce borders/distortion. Smaller logical sizes make the interface larger. Each logical dimension is doubled for HiDPI rendering. This version limits backing dimensions to 8192 and accepts at most 100 sizes per request; hardware limits may be lower.

Review the displayed model and restore command. To install:

```sh
sudo ./bin/scalectl add --display DISPLAY_UUID --sizes 1600x900,1920x1080,2048x1152 --apply
```

Save your work and reboot manually. Then list modes again:

```sh
./bin/scalectl modes --display DISPLAY_UUID
```

Only modes that macOS actually accepts will appear. You can select them in this tool or System Settings → Displays (enable the full resolution list if necessary). Requesting an override is not proof that a size is supported.

An installed override applies to **every display with that vendor/product identity**, not just the chosen unit. Avoid applying display configuration from BetterDisplay or another tool while managing the same model with scalectl.

## Select a mode

Copy a decimal `MODE ID` from the current `modes` listing:

```sh
./bin/scalectl set --display DISPLAY_UUID --mode MODE_ID
```

Run this as your normal user in a local Terminal, without `sudo`. Type `yes` and Enter within 15 seconds to keep the change. Otherwise the CLI attempts to restore the saved mode. Use `--timeout 30` for more time (5–60 seconds). Ctrl-C, termination and hangup signals are ignored during this interval so the confirmation timer can finish. A forced kill, process crash, device removal, or WindowServer failure can prevent restoration; the timer is not a separate watchdog. The selection is session-scoped, not an automatic login profile.

## Restore the original configuration

`add` prints the model-specific restore command. Replace `VENDOR_HEX` and `PRODUCT_HEX` with the hexadecimal values from that command or `displays`:

```sh
./bin/scalectl restore --vendor VENDOR_HEX --product PRODUCT_HEX
sudo ./bin/scalectl restore --vendor VENDOR_HEX --product PRODUCT_HEX --apply
```

Reboot afterward. Restore works even if the target display is offline. If no override existed originally, only the file created for that model is removed. If an override existed, its original bytes and file permissions are restored. Other files and vendor directories are left in place. To install a different resolution list, restore first, then add the new list.

The backup is stored at `/Library/Application Support/ScaleCLI/<vendor>-<product>.plist`. It contains the original file (if any), its permissions, and a fingerprint of the installed file. If another tool changes the override, restoration refuses to overwrite those changes. Preserve the backup and inspect the difference before resolving a conflict; there is deliberately no force-overwrite switch.

If the display becomes unusable after reboot, use another display, remote access already configured on your Mac, or Safe Mode to run the restore command, then reboot. Do not delete whole vendor directories: they can contain unrelated configuration.

## What it changes

On `add --apply` only, the tool merges extra `scale-resolutions` entries into:

```text
/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<vendor>/DisplayProductID-<product>
```

It preserves unrelated keys and existing mode entries. Each requested size adds a HiDPI request and its ordinary backing/logical size entries, with duplicates removed. It does not change your display's name, native dimensions, default mode, refresh settings, EDID, monitor firmware, or WindowServer preferences. No automatic reboot or display reinitialization is performed.

System writes require administrator privileges. The tool restricts itself to fixed system directories, checks ownership and permissions when privileged, rejects symlinks/hard-linked files/special paths, uses atomic file replacement, records the backup before writing, and locks concurrent scalectl operations. An existing backup is never overwritten. It does not install a privileged helper or ask you to disable SIP.

The override encoding is undocumented and could change between macOS versions. Native overrides are intended for built-in/natively connected panels; DisplayLink, Sidecar, AirPlay, and other managed displays may ignore them. This version does not implement the alternative virtual-display approach.

## Build and verify

Requires Swift 6+ and Apple Command Line Tools. Full Xcode is not required. There are no package downloads.

```sh
./scripts/build.sh
./scripts/check.sh
```

The checks exercise binary mode encoding and limits, non-destructive merging, malformed plist rejection, byte-for-byte backup restoration, new-file removal, conflict detection, symlink/hardlink rejection, permissions, operation locking, interrupted-install recovery, and confirmation timeout/input/error behavior. They use temporary directories and do not change system display settings. They are a separate executable so Apple's Command Line Tools can run them without XCTest from full Xcode.

The confirmation wait uses `select`, since macOS can return `POLLNVAL` immediately when `poll` is used on `/dev/tty`. The check script also creates a pseudo-terminal to verify that the actual controlling terminal waits for its deadline, then runs read-only CLI smoke checks. These checks work on CI machines without physical displays. Terminal input failures are reported as errors and still trigger a rollback attempt.

## Releases

CI runs native builds and read-only checks on both Apple Silicon and Intel macOS runners for pull requests and changes to `main`. The [release workflow](.github/workflows/release.yml) repeats those checks for a version tag, builds one archive per architecture, verifies SHA-256 checksums, and publishes a GitHub release with generated notes. Tags with a suffix such as `v0.1.0-rc.1` create prereleases.

After the source is committed and pushed, create a release by tagging the intended commit:

```sh
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

To check packaging locally without creating or publishing a release:

```sh
./scripts/package.sh v0.1.0
```

Files are written to the ignored `dist/` folder. The workflow uses the built-in `GITHUB_TOKEN`; no personal access token or Apple signing credentials are needed. Actions are pinned to commit SHAs, checkout does not persist credentials, and only the publishing job receives release write access. If publication fails, inspect the existing tag/release before retrying; the workflow does not overwrite existing release assets.

For a packaging or workflow failure before publication, fix the release tooling through a pull request, then dispatch the workflow from `main` for the existing tag:

```sh
gh workflow run release.yml --ref main -f tag=v0.0.1
```

The workflow checks out application source from that unchanged version tag and packaging tools from the workflow commit, and verifies that the tagged source is an ancestor of `main`. It does not move protected tags. CI exercises packaging on both architectures to catch toolchain compatibility problems before a release. The packaging helper also accepts an optional source-directory argument for testing this arrangement locally.

Repository-wide agent instructions live in [AGENTS.md](AGENTS.md), with references for Claude and GitHub Copilot.

## Implementation references

- [Apple Quartz Display Services](https://developer.apple.com/documentation/CoreGraphics/quartz-display-services): enumeration and session mode changes.
- [BetterDisplay system configuration guide](https://betterdisplay.pro/guide/interface-reference/settings/displays/display/system-configuration/): model overrides, flexible scaling, activation and compatibility.
- [Native override format described by hidpi](https://github.com/kirakirag/hidpi): observed big-endian scale-resolution records. This project implements its own merge, validation, backup and restore behavior.

The binary is locally built and ad-hoc signed, not notarized for general distribution. Review the supplied source before running any locally built tool with `sudo`.
