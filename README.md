# Project Reignition for iOS

An iPhone and iPad port of **Project Reignition**, the fan remake of *Sonic and the Secret Rings* made with Godot 4.7 and C#. The game is built from [Project Reignition's source](https://github.com/kumapauz/project-reignition) by kumapauz with Godot's Mobile renderer on Metal, and its C# code is compiled ahead of time with .NET NativeAOT. This repository is a fork of Project Reignition with the iOS port in [`ios/`](ios/): touch controls, iOS fixes and the build script that turns the game's source into an IPA.

**The cutscene videos are not in the repository.** To build, take them from Project Reignition's official PC build on [GameJolt](https://gamejolt.com/games/project_reignition/1082591).

**[Releases](https://github.com/DevZer0D4Y/ProjectReignition-iOS/releases)** · [Changelog](CHANGELOG.md)

If you want to support me and remain up-to-date about this and other projects, you can in different ways:

Ko-Fi: https://ko-fi.com/dev_zer0

Discord: https://discord.gg/uFChheZEWX

YouTube: https://www.youtube.com/@develop_erZ

## Features

- The whole remake, built from Project Reignition's source for iPhone and iPad.
- Up to 120 FPS on ProMotion screens.
- On-screen touch controls that act as an Xbox controller, so every menu, move and button prompt works. They hide while a controller is connected.
- Controller support (MFi, Xbox, PlayStation).
- Cutscenes played as Ogg Theora, since the PC build's H.264 player has no iOS version.
- Saves, settings and mods in the app's folder in the Files app, kept across updates.
- Lost Prologue's bloom working on the Mobile renderer.
- Effects drawn as on PC: Godot's Mobile renderer ignores the fade the game uses for the homing attack's aura, item box glows and debris, and halves multiply-blended effects; the port makes up for both.
- Garbage collections run during loading screens instead of during gameplay.
- Apple Game Mode support on compatible devices and iOS versions.

## Requirements

- An iPhone or iPad running **iOS/iPadOS 15 or later**, with an A15 Bionic or newer (iPhone 13 and later). Development and playtesting have used an **iPhone 14 Pro Max** and an **iPhone 16 Pro Max**.
- About **6 GB** of free storage while installing: the IPA is about 1.8 GB and the installed game about 2.5 GB.
- A sideloading tool to sign and install the IPA, such as ESign, AltStore, SideStore or Sideloadly.

A controller is recommended, but the game can also be played with touch controls.

## Installation

1. Obtain the IPA from a [release](https://github.com/DevZer0D4Y/ProjectReignition-iOS/releases) or [build it from source](#building).
2. Sign and install it with your preferred sideloading tool. With ESign, import the IPA, then sign and install it inside ESign.
3. Open **Sonic and the Secret Rings Remake**.

To update an existing installation, use the same signing identity and bundle identifier (`com.devz.projectreignition`) to keep your saves.

### Saves and mods

The game's folder is in **Files → On My iPhone → Sonic and the Secret Rings Remake**:

```text
Sonic and the Secret Rings Remake/
├── saves/            Save slots, shared progress and time attack records
├── config.cfg        Settings, once you change an option
├── mods/             Mods: characters, lang, levels and extras
├── logs/godot.log    Log of the last session
└── shader_cache/     Compiled shaders, rebuilt if deleted
```

## Playing and settings

The touch gamepad appears automatically when no controller is connected. Settings are in the game's Options menu. The iOS build starts with lighter defaults than the PC version:

| Option | iOS default | PC default |
|---|---|---|
| Framerate | 120 | 60 |
| Reflection quality | Medium (half resolution) | High |
| Soft shadows | Low | Medium |

Low Power Mode limits the screen, and so the game, to 60 FPS.

## Status and known issues

Current version: **1.0.9 (build 5)**.

- The first visit to an area can stutter briefly while its shaders compile. Later visits use the shader cache.
- A hot phone, after a long session or while charging, runs slower as iOS lowers its clock speeds.
- Party mode's local network play has not been tested.

## Building

Requires an **Apple Silicon Mac** with **Xcode**, the **.NET 10 SDK**, **Godot 4.7.2 (.NET)** with its iOS export template, **FFmpeg** and **libtheora** (`brew install ffmpeg theora`).

The repository is large (about 6.6 GB with history); `--depth 1` downloads only the current version. Take the cutscene videos from the official PC build's `.pck`, then run the build from the repository root:

```sh
git clone --depth 1 https://github.com/DevZer0D4Y/ProjectReignition-iOS
cd ProjectReignition-iOS
python3 ios/tools/pck_tool.py extract "Sonic and the Secret Rings Remake.pck" ../videos '*.mp4'
GODOT=/path/to/Godot_mono.app/Contents/MacOS/Godot VIDEOS=../videos bash ios/scripts/build_ios.sh
```

The script copies the overlay into `Project/`, applies the iOS settings and patches there (`git checkout Project` undoes them), converts the videos, builds the C# code, exports the Xcode project, builds it and packages:

```text
out/ProjectReignition-1.0.9.ipa
```

Pass a checkout and an output folder as arguments to build elsewhere, for example on an external drive. The IPA is unsigned; sign it with your sideloading tool before installing. Optional settings:

| Variable | Default | Description |
|---|---|---|
| `TEXTURE_LIMIT` | `640` | Largest side of 3D textures in pixels. 640 keeps the IPA under GitHub's 2 GB limit. |
| `VERSION` / `BUILD` | `1.0.9` / `1` | The app's version and build number. |

### Testing tools

`ios/overlay/ios/PerfProbe.cs` writes frame times to `logs/godot.log` (`PERF` lines every 5 seconds, `HITCH` lines for long frames) and has test modes, started from the Mac with environment variables:

```sh
xcrun devicectl device process launch --device <device> \
    --environment-variables '{"PR_BENCH": "lost prologue/Classic1", "PR_BENCH_SECONDS": "60"}' \
    com.devz.projectreignition
```

`PR_BENCH` loads a level straight from boot, lets Autorun play it and logs a `BENCH` summary at the end. `PR_SAVE_TEST=1` saves, reloads and deletes a spare save slot and logs `SAVETEST`. Settings such as `PR_FPS`, `PR_SCALE` and `PR_SHADOWS` apply to one run only; the comment at the top of the file lists them all.

## Source layout

| Path | Contents |
|---|---|
| [`ios/overlay/`](ios/overlay/) | Files copied over the game: touch controls, video player, Lost Prologue's bloom, Mobile renderer fixes, garbage collection, testing tools and the iOS export preset |
| [`ios/scripts/apply_ios_settings.py`](ios/scripts/apply_ios_settings.py) | iOS project settings and the patches to the game's code |
| [`ios/scripts/build_ios.sh`](ios/scripts/build_ios.sh) | Overlay, import, C#, export, Xcode build and IPA packaging |
| [`ios/tools/`](ios/tools/) | Video conversion to Ogg Theora and a `.pck` extractor |

Project Reignition's own source is unchanged in [`Project/`](Project/) and [`misc/`](misc/).

## Credits

- [Project Reignition](https://github.com/kumapauz/project-reignition) by **kumapauz** and its contributors.
- The [Godot Engine](https://godotengine.org) and its .NET support.
- *Sonic and the Secret Rings* by **SEGA** and **Sonic Team**.

## License

This repository is distributed under the [Open Sonic Fan Game License](LICENSE.md), Project Reignition's license. Project Reignition's graphical assets are owned by SEGA and are used under that license solely within Project Reignition.

This is an unofficial fan project, unaffiliated with and not endorsed by SEGA, and it must not be sold. No signing certificates or provisioning profiles are distributed with this source.

## Support and community

[Ko-Fi](https://ko-fi.com/dev_zer0) · [Discord](https://discord.gg/uFChheZEWX) · [YouTube](https://www.youtube.com/@develop_erZ)
