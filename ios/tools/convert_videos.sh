#!/bin/bash
# Converts the game's H.264 videos (from the official build's pack) to Ogg
# Theora, which Godot plays on every platform, including iOS where the
# FFmpeg GDExtension the desktop builds use is not available.
# Usage: convert_videos.sh <dir with video/...mp4> <project dir> [quality]
set -euo pipefail
source="$1"; project="$2"; quality="${3:-44}"
here="$(cd "$(dirname "$0")" && pwd)"
encoder="$here/y4m2ogv"
[ -x "$encoder" ] || clang -O2 -o "$encoder" "$here/y4m2ogv.c" $(pkg-config --cflags --libs theoraenc ogg)
cd "$source"
find video -name '*.mp4' | sort | while read -r mp4; do
    ogv="$project/${mp4%.mp4}.ogv"
    [ -s "$ogv" ] && continue
    mkdir -p "$(dirname "$ogv")"
    # Even dimensions for 4:2:0; the few odd-sized clips lose one pixel row.
    ffmpeg -nostdin -v error -i "$mp4" -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2" -f yuv4mpegpipe -pix_fmt yuv420p - \
        | "$encoder" "$quality" "$ogv.partial"
    mv "$ogv.partial" "$ogv"
    echo "$(stat -f %z "$ogv") $ogv"
done
