---
lang: en
---

# Vista Privacy Policy

[繁體中文](隱私權聲明.md)

Updated: November 15, 2026. This policy describes how Vista currently handles data.

## Videos and connections

Vista reads the videos you select and the information needed for playback, including file names, folders, file attributes, supported tags, and audio/video specifications. Videos may come from local folders you authorize or SMB servers you configure. Playback may create temporary files, buffers, or segments on your device.

When using SMB, Vista exchanges authentication information, directory requests, and file-read requests with the server you specify. The server may see your source IP address, account, and access records. Those records depend on the server administrator’s settings and policies. Network and server protections also affect transport security; this policy does not promise that all SMB connections use the same encryption.

For local folders, Vista saves the access authorization provided by the system. If another file service provides the folder, its downloads, synchronization, and storage are also subject to that service’s policies. Some playback processing transfers segments through a service bound only to the device’s loopback address. This is different from uploading to an external website.

## Saved settings and credentials

Vista saves source names, servers, shares, usernames, folder authorizations, shortcuts, and display preferences on your device. Per-video format choices use locally derived identifiers to recognize the same video again. This does not mean that all settings or identifiers are anonymized or encrypted.

SMB passwords are stored in Vista-specific system Keychain items, configured for this device, readable when unlocked, and excluded from Keychain synchronization. Ordinary connection settings do not write passwords into settings JSON. System backups, device management, and file services may handle data separately; the Keychain configuration is not a promise that all Vista data is excluded from backups.

## Head pose and interaction

Vista uses system-provided head position, orientation, and interaction information to place the video and controls, sampling pose during operations such as loading, resetting, or dragging. Diagnostics also save some headset/controller positions, orientations, gravity measurements, and sampling times to investigate placement and interaction issues. This information may reflect spatial position and usage patterns; the absence of a name does not make it entirely non-sensitive.

Vista uses system gestures and head tracking. It does not include camera-image or microphone-recording capture features and does not obtain raw eye-gaze points. The system’s handling of sensor data is governed by Apple’s information and settings.

## Diagnostics and sharing

Vista records playback, source reads, errors, performance, interaction events, and some pose diagnostics on the device. Different records have different size and retention rules: some rotate by size or date, while others stop recording when a capacity limit is reached. There is no promise that every record is automatically deleted after a fixed number of days.

Vista does not provide a feature that automatically uploads videos or diagnostics to a developer server, and it does not integrate advertising or third-party analytics services. The servers, file services, and operating system you use still handle data under their own policies.

If you agree to retrieve logs to a computer or share them with a maintainer for troubleshooting, those copies leave the headset. Review their contents before sharing. Do not post credentials, private videos, private paths, or unreviewed complete diagnostics in public Issues. Information and account details you submit through GitHub are also subject to GitHub’s policies.

## Managing your data

You can edit sources, remove sources and their shortcuts, or reauthorize local folders in Vista. Removing an SMB source also removes its corresponding Keychain password; it does not delete videos from the server. Removing a source does not necessarily clear every per-video preference or diagnostic record.

There is currently no single in-app button that clears all preferences, diagnostics, and external copies. App removal, Keychain, backups, and previously shared copies may have different deletion rules; do not assume that uninstalling removes all related data. For data-handling questions, start with a question containing no personal information at [project Issues](https://github.com/peiyu66/Vista/issues) so an appropriate private contact method can be arranged.

## Third parties and policy updates

Playback and file access use Apple system frameworks and the third-party components listed at [third-party notices](ThirdPartyNotices.en.md). This policy does not replace their policies or those of the servers and file services you choose.

This policy and its date will be updated when data handling changes. Technical review scope: [data-handling review](development/資料處理核對.md).
