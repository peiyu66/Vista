#!/bin/sh
# Test-only generation with an already installed FFmpeg; never linked or bundled in Vista.
# Usage: sh tools/GenerateSyntheticVP9.sh OUTPUT_DIRECTORY
# Generates pixels, encodes VP9, then remuxes without video decoding.
set -eu
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'An existing output directory is required.' >&2; exit 1; }
command -v ffmpeg >/dev/null
[ ! -e "$1/SyntheticVP9.mp4" ] && [ ! -e "$1/SyntheticVP9.mkv" ] || { echo 'Refusing to overwrite fixtures.' >&2; exit 1; }
ffmpeg -hide_banner -loglevel error -n -f lavfi -i 'color=c=gray:s=64x64:r=12:d=2' -an -c:v libvpx-vp9 -profile:v 0 -pix_fmt yuv420p -b:v 40k -map_metadata -1 "$1/SyntheticVP9.mp4"
ffmpeg -hide_banner -loglevel error -n -i "$1/SyntheticVP9.mp4" -map 0:v:0 -c copy -map_metadata -1 "$1/SyntheticVP9.mkv"
