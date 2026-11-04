# Files, recordings and footer update

## What is implemented
- Per-profile local/Windows network folder shortcuts, stored with SharedPreferences; no database migration.
- Browse subfolders, search loaded entries, preview supported raster images, play supported video/audio inside Millitop with media_kit/libmpv.
- DVR tab reads configured recording folders. Videos and audio are listed; files still being written may not play to completion. There is no scheduling, recording service, wake-from-sleep support or stream-credential integration.
- Open IPTVnator/Open VLC reuse the existing application launcher. They launch those apps; they do not start or schedule recordings or automatically change their output folders.
- Connected, Switch profile and Quit share one responsive launcher footer. Long names are shown in the footer text/tooltip; the Switch profile action stays legible. The old independently positioned profile overlay is removed.
- Playback keeps the existing media-active update guard set until native player shutdown is confirmed. A failed shutdown leaves updates blocked; Quit/reopen before updating. Native player creation is deferred until a media file is opened, so it is not required for startup confirmation.

## Folder access and limits
Select a directory with the Windows folder picker. Network shares use the current Windows account and its existing access; this feature does not collect/store a network password, map drives or bypass permissions. Profile shortcuts are convenience separation, not a filesystem security boundary. Browsing/preview is read-only. Removing a shortcut does not delete files. Symlink entries are not followed and canonical paths must stay within the selected root. Executables, scripts, shortcut files, URLs and playlists are not launched by the file browser.

The browser lists up to 2,000 entries in the current directory, not an unbounded recursive scan. Search filters the loaded list only; a cap warning is shown. Refresh is manual to pick up new recordings. Image preview is limited to 100 MB with bounded decode width. Codec/DRM support is not guaranteed by a filename extension; unsupported/protected/unfinished media reports an error. No files are uploaded to the dashboard by this feature.

## New native dependencies and distribution review
Pinned Dart packages: media_kit 1.2.6, media_kit_video 2.0.1, media_kit_libs_video 1.0.7. Native Windows playback libraries are bundled by the package build and increase installer size. The existing Inno builder copies the full release bundle.

Review license notices, source/relinking/redistribution requirements and codec rights for the exact resolved native libmpv/FFmpeg binaries before a production distribution. The Dart wrapper's license is not by itself the license of every bundled native component. This patch is not a licensing certification. Include appropriate third-party notices/source offers as required for the actual binary build you ship. A one-device pilot does not establish production compliance or clean-machine compatibility.

## Installation and release
Run the supplied patch installer on the development PC. It refuses to change source while an earlier pipeline run is unfinished or the project release lock is held. Finish the previous release with .\release.cmd -Resume first. Source files must match the uploaded 19:02 export; otherwise stop and obtain a current export.

The patch backs up changed sources/config outside the project, adds dependencies, formats changed Dart, runs analysis and all tests, and verifies protected updater/launcher/pipeline files are unchanged. Without -Release it does not build, sign, upload or register anything. Passing -Release explicitly invokes the existing release command after checks pass and after releasing the project lock. This builds/signs/publishes/registers a paused release, without assigning devices. Alternatively, run the existing release pipeline separately:

    .\release.cmd

Release configuration is raised to at least 1.3.0, and release notes are updated. Build number remains automatic. The pipeline leaves the new release paused; assign/enable only the test PC and approve the update normally.

## Pilot acceptance
1. Verify the updated app is the expected version and dashboard startup status is verified.
2. At wide and narrow window widths, confirm Connected, Switch profile and Quit are separate and clickable. Switch profiles and verify the displayed name changes.
3. In Files, add a local directory and a permitted Windows share; browse within Millitop, open a photo, video and audio file, seek/pause/change volume, then return to its folder.
4. Add a recordings folder in DVR. Make an authorized recording in an external recorder using that folder, refresh in Millitop and play it. No recording should be started by clicking Browse or opening the DVR tab.
5. Test an unavailable share, removed file and unsupported/DRM-protected file. The app must show a useful error and allow Back, not claim successful playback.
6. Remove a shortcut and confirm the real files remain; switch profiles and confirm shortcuts are separate.
7. During playback the updater should refuse installation; after a clean player close it should be permitted again. Quit must still work on the launcher.
