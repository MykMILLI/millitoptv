# Dashboard release policy

Every Windows release deployed to the MILLITOP TV admin dashboard must also
include an Android APK with the same version and build number. Build and verify
the APK before publishing Windows; do not report a Windows-only deployment as
complete. If either platform fails, report the blocked paired release explicitly.

Publish the APK in dashboard Quick downloads, verify the complete public download
against its SHA-256, and confirm the deployed dashboard contains its download card.
Preserve existing Android signing/update compatibility. Until production signing
is configured, clearly label the APK as development-key-signed for sideload
testing; never silently replace signing keys.

Keep required GPLv3 corresponding source available alongside both binaries.
Use the existing Windows signing/publishing pipeline and the process in
[the release guide](../tools/README-release.md). Publication must not silently
enable automatic rollout or assign devices.
