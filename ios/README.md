# OpenMW for iOS and iPadOS (unofficial port)

This branch (`openmw-ios`) ports OpenMW 0.52 to iPad and iPhone. It renders with desktop OpenGL through Mesa's
Zink driver on MoltenVK (Vulkan on Metal) and uses SDL2's UIKit backend, so the engine runs largely unchanged.

This is an unofficial port: it is not supported by the OpenMW team, so please don't ask about it on the OpenMW
forums. The app contains no game data: you need your own copy of Morrowind for the PC. OpenMW is licensed under the
GPLv3 (see [LICENSE](../LICENSE)); the dependencies come with their own licenses, whose notices the app carries in its
`licenses` folder (see [licenses/README.txt](licenses/README.txt)).

## Requirements

- A Mac with Apple silicon and Xcode 27.1 with the iOS 27 platform installed (Xcode > Settings > Components).
  Tested on macOS 27 (M2 Pro) with Python 3.14; other Xcode versions are untested.
- [Homebrew](https://brew.sh) with the host tools the build uses:

  ```
  brew install cmake ninja meson xcodegen pkgconf python bison
  ```
- Network access for the first build (it downloads about 0.8 GB of pinned dependency sources) and about 10 GB of
  disk space.
- A device with iOS or iPadOS 18.0 or later. The app is made for the iPad; on the iPhone it runs in landscape only and
  the user interface is not adapted to the small screen.
- For device builds: an Apple Developer team. The app uses the Increased Memory Limit capability; a free Personal
  Team is untested.

## Building

```
git clone --branch openmw-ios https://github.com/joedemo42/OpenMW.git
cd OpenMW
./build-ios.sh build
```

`build` builds a debug app for the iOS Simulator. The first run builds all dependencies from source (MoltenVK, Mesa,
SDL2, OpenSceneGraph, Boost, ICU, FFmpeg, OpenAL Soft and more) into `ios-deps/` and takes about 20 minutes on an
M2 Pro; the first device build adds about 10 minutes for the device libraries. Later builds are incremental. The
app does not run in the Simulator, though (see Known limitations): to play, build for a device.

### Device builds

Device builds are signed with your own team and bundle ID. Copy `ios/build.config.sample` to `ios/build.config`
(git-ignored) and fill in at least:

```
TEAM_ID=<your Apple Developer Team ID>
BUNDLE_ID=<a bundle ID of your own, e.g. com.example.openmw>
```

The same file can set the home-screen name (`APP_NAME`) and the app icon (`APP_ICON`). Then, with the device
connected:

```
./build-ios.sh build device --release
./build-ios.sh install --release --device "<device name or UDID>"
```

`--release` builds an optimized app; without it you get a debug build. `./build-ios.sh ipa --release` packages the
current device build as an IPA in `DerivedData/ipa/`. `./build-ios.sh --help` lists all commands; the dependencies
can also be built on their own with `./build-ios.sh deps build all`. The dependency versions are pinned in
`ios-deps/recipes/`, the patches applied to them are described in
[ios-deps/patches/README.md](../ios-deps/patches/README.md).

## Game data

1. Install the app and launch it. After a one-time notice that this is an unofficial port, it shows "Game files
   needed" and creates the folders `Config` and `Data` in its documents: Files app > On My iPad > OpenMW (or the
   `APP_NAME` you chose), or in Finder on a Mac: the device > Files.
2. From your PC installation of Morrowind, copy the contents of the `Data Files` folder into `Data` (keep the folder
   structure: `Morrowind.esm`, `Morrowind.bsa`, `Meshes/`, `Textures/`, ...) and `Morrowind.ini` into `Config`. An
   ini copied into `Data` along with the game files is moved to `Config` by the app.
3. Launch the app again. It imports `Morrowind.ini` once (content files, archives, game settings) into
   `Config/openmw.cfg` and starts the game.

The app's documents also hold `Saves/`, `Screenshots/`, `Logs/openmw.log` (attach it to bug reports) and
`Config/settings.cfg`. To import the ini again, delete `Config/openmw.cfg` and relaunch. There is no launcher on iOS:
add mods with `data=` and `content=` lines in `Config/openmw.cfg` (paths relative to `Config/`, e.g.
`data="../Mods/MyMod"`).

For development, `./build-ios.sh documents zip` packs a `Data/` folder in the repository root into
`DerivedData/ipa/Documents.zip`, and `./build-ios.sh documents install` copies it into the installed app. Keep that
folder out of git, e.g. with a `/Data/` line in `.git/info/exclude`.

## Controls and iOS options

- Keyboard with mouse or trackpad, game controllers, or on-screen touch controls when nothing is connected (a
  two-finger tap opens the game menu). Menus switch to the controller layout automatically.
- Options > Video has iOS-specific settings: Render Scale (50 to 200 % of the display resolution), MetalFX Upscaling
  and MetalFX Sharpening, Frame Rate Limit (60 fps by default) and the Metal Performance HUD.

## Known limitations

- Rendering is limited to OpenGL 2.1 (compatibility profile) and GLSL 1.20, which is what Zink offers on MoltenVK.
  Mesa stays on 25.1, because newer Zink versions need a Vulkan feature MoltenVK lacks.
- Each frame is copied into a Metal layer for display, which adds one frame of latency.
- The app builds for the iOS Simulator but exits a few seconds after launch there: the Simulator's GPU lacks features
  MoltenVK needs. Use a device.
- No launcher, installation wizard, editor (OpenMW-CS) or command-line tools.
- LuaJIT runs as an interpreter only (iOS does not allow code generation at runtime).
- The ini import assumes Windows-1252 game data (English, German, French, ...); other encodings are untested.

## Binary releases

An IPA you pass on to others must come with its source code (GPLv3); FFmpeg, OpenAL Soft and parts of OpenSceneGraph
are licensed under the LGPL, so the release must also say where their source is.

1. Commit and tag the state you release and build it from a checkout without local changes (`git status --short`
   prints nothing), so the revision in the main menu is the tagged commit:

   ```
   ./build-ios.sh build device --release
   ./build-ios.sh ipa --release --unsigned
   ```

   The unsigned IPA (`DerivedData/ipa/OpenMW-unsigned.ipa`) is for others to sign with their own team. A signed one
   contains your provisioning profile (team, certificate name, registered device IDs) and installs only on those
   devices. Your `BUNDLE_ID` and `APP_NAME` stay in the IPA's Info.plist.
2. Publish the IPA, name the tag as the release's source and link the source archives of FFmpeg, OpenAL Soft and
   OpenSceneGraph: their pinned download URLs are in `ios-deps/recipes/`, the archives the build used in
   `ios-deps/source/`. Give each link the archive's SHA-256, so anyone can check it is the source the app was built
   from. The build scripts fetch the other dependencies from the pinned URLs in `ios-deps/recipes/` as well.

With the source and these scripts, anyone can rebuild the app with modified versions of these libraries; installing
it needs their own signing. The app carries the license notices of OpenMW and its libraries in its `licenses` folder.
The App Store and TestFlight are not covered here: Apple's terms are widely considered incompatible with the GPL.

## Repository layout

- `build-ios.sh`: entry point for all commands.
- `ios/`: the app host (`project.yml` for xcodegen, `OpenMW/` with Info.plist, entitlements and icon, `licenses/` with
  the index of the app's license notices), `build.sh` (app build, install, run, IPA) and `perf.sh` (profiling on a
  device).
- `ios-deps/`: `build-deps.sh` builds the dependencies as xcframeworks from the recipes in `recipes/` and the patches
  in `patches/`.
- iOS code in the engine: `apps/openmw/ios/` (first launch, platform integration, MetalFX) and
  `components/files/iospath.*` (paths).
