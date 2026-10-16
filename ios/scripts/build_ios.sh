#!/bin/bash
# Builds Project Reignition for iPhone and iPad: applies the iOS overlay to a
# checkout, exports the Godot project as an Xcode project, builds it and
# packages an IPA for sideloading (AltStore, SideStore, ESign).
#
# Usage: build_ios.sh [checkout root (with Project/)] [output dir]
#   By default this repository and its out/ folder. The overlay and patches
#   are applied to the checkout's Project/ folder in place.
# Environment:
#   GODOT          the Godot 4.7.x .NET editor binary
#   VIDEOS         a folder with the official build's videos as .mp4 (video/...),
#                  converted to Ogg Theora where the .ogv is missing
#   TEXTURE_LIMIT  largest side of 3D textures in pixels (default 640)
#   VERSION/BUILD  CFBundleShortVersionString / CFBundleVersion
# The output folder can be on an external drive (the IPA is about 2 GB).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
checkout="$(cd "${1:-$here/..}" && pwd)"
output="$(mkdir -p "${2:-$checkout/out}" && cd "${2:-$checkout/out}" && pwd)"
project="$checkout/Project"
godot="${GODOT:-/Applications/Godot_mono.app/Contents/MacOS/Godot}"
version="${VERSION:-1.0.9}"
build="${BUILD:-1}"
[ -f "$project/project.godot" ] || { echo "no Godot project in $project" >&2; exit 1; }

echo "== overlay"
cp -R "$here/overlay/." "$project/"
# The app icon is the game's own, scaled to the 1024 px iOS needs and
# flattened onto black (iOS icons have no transparency).
ffmpeg -v error -y -f lavfi -i color=black:s=1024x1024 -i "$project/interface/boot/Icon.png" \
    -filter_complex "[1]scale=1024:1024:flags=bicubic[i];[0][i]overlay=format=auto,format=rgb24" \
    -frames:v 1 "$project/ios/icon_1024.png"
python3 "$here/scripts/apply_ios_settings.py" "$project" --mobile-import-only --texture-limit "${TEXTURE_LIMIT:-640}"
sed -i '' -e "s/^application\/short_version=.*/application\/short_version=\"$version\"/" \
          -e "s/^application\/version=.*/application\/version=\"$build\"/" "$project/export_presets.cfg"

if [ -n "${VIDEOS:-}" ]; then
    echo "== videos"
    nice -n 19 "$here/tools/convert_videos.sh" "$VIDEOS" "$project" 44
fi

echo "== import, C# and export"
# The editor needs the Debug assembly to know the scripts' exported
# properties while it converts scenes; without it they are dropped.
(cd "$project" && nice -n 19 dotnet build "Sonic Remake Project.csproj" -c Debug -v minimal)
nice -n 19 "$godot" --headless --path "$project" --import
xcode="$output/xcode"
rm -rf "$xcode"
mkdir -p "$xcode"
nice -n 19 "$godot" --headless --path "$project" --export-release "iOS" "$xcode/ProjectReignition.ipa"
xcodeproj="$(find "$xcode" -maxdepth 1 -name '*.xcodeproj' | head -1)"
[ -n "$xcodeproj" ] || { echo "the export made no Xcode project" >&2; exit 1; }

echo "== xcodebuild"
derived="$output/derived"
nice -n 19 xcodebuild -project "$xcodeproj" -scheme "$(basename "$xcodeproj" .xcodeproj)" -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$derived" -jobs 2 \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
app="$(find "$derived/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$app" ] || { echo "xcodebuild made no app" >&2; exit 1; }

echo "== ipa"
staging="$output/staging"
rm -rf "$staging"
mkdir -p "$staging/Payload"
bundle="$staging/Payload/$(basename "$app")"
ditto --noextattr --norsrc "$app" "$bundle"
find "$bundle" -name '._*' -delete
# Ad hoc signatures; the sideloading app signs the bundle again with the
# player's certificate and keeps these entitlements (more memory).
entitlements="$(find "$xcode" -name '*.entitlements' | head -1)"
find "$bundle/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) | while read -r item; do
    codesign --force --sign - --timestamp=none "$item"
done
codesign --force --sign - --timestamp=none ${entitlements:+--entitlements "$entitlements"} "$bundle"
ipa="$output/ProjectReignition-$version.ipa"
rm -f "$ipa"
(cd "$staging" && nice -n 19 zip -qry -6 "$ipa" Payload -x '*/._*' '*.DS_Store')
echo "IPA: $ipa ($(du -h "$ipa" | cut -f1))"
