# User guide and compatibility

[中文](使用說明.md)

[Back to Home](../README.en.md)

## Choose a video

Add an SMB server using credentials you are authorized to use, or authorize a local folder through the system picker. You can create shortcuts to frequently used folders. Connection settings are saved; SMB passwords are stored separately in the system Keychain. Removing a source does not delete the original videos.

## Demo videos

Download a [demo video](DemoVideo.en.md) and follow the steps on that page to play it in Vista. The waterfall clip is a 360° monoscopic panorama, not side-by-side stereo; the download page also provides its source and license.

## Playback

Select a video, then use the playback controller to pause, play, switch videos, or seek. Drag the timeline to choose a playback position. Available playback speeds depend on the video. High speeds or demanding videos may still stall; reduce the speed if needed.

Choose 180°, 360°, or centered equidistant fisheye projection, and mono, side-by-side, or over-under layout as appropriate. Format choices can be saved per video. Projection settings cannot correct every lens or file. Compatibility also depends on the video codec, specifications, and audio, not just the file extension.

## Controller and viewing direction

Tap the background once to show or hide the controller, double-tap to return the controller to its default position, and pinch and hold to reset the video direction. Grab the bottom drag bar to move the controller. Look at the control you want to use: the timeline thumb seeks within the video, while the bottom drag bar moves the controller.

Returning the controller to its default position samples the headset’s current position and orientation again, supporting changes between sitting and reclining. Resetting the video direction is separate from repositioning the controller; resetting video angles only clears the direction offsets. Looking upward beyond the configured threshold applies a viewing adjustment. This does not identify your body posture.

## Format and playback limits

HEVC and VP9 have been tested through the MKV playback path, but this does not mean every MKV, codec, audio channel layout, or HDR combination is supported. Seeking or reducing playback speed may still cause a pause. If a problem occurs, note the video format and the operation you performed.

There is currently no App Store download. For the public source and development validation scope, see the [development documents](development/開發文件入口.md).

## Report a problem

Describe the app version, steps, and symptoms in [GitHub Issues](https://github.com/peiyu66/Vista/issues). Vista support does not ask you to upload diagnostic logs. Do not attach logs, credentials, private videos, or private file names and paths. Issues and your public account information are visible to maintainers and other people. See the [privacy policy](PrivacyPolicy.en.md) for details.
