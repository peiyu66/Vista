#!/bin/sh
set -eu
# Test asset only: requires an existing ffmpeg with libx265. No runtime decoder dependency.
# Run from repository root. Refuse to overwrite an existing fixture.
ffmpeg -hide_banner -loglevel error -f lavfi \
  -i 'testsrc2=size=320x180:rate=30:duration=14' \
  -c:v libx265 -preset fast \
  -x265-params 'keyint=60:min-keyint=60:scenecut=0:open-gop=1:bframes=4:pools=2:frame-threads=2' \
  -tag:v hvc1 -an -n Tests/VistaCoreTests/Resources/OpenGOPHEVC.mp4
