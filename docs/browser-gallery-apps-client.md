# Browser, Gallery, Settings and web-app client release

## Scope
This client patch is for the current exported Files/DVR build and the managed-web-app backend already deployed. It implements:
- Actual desktop Firefox for website apps, with per-household-profile browser data, cookies, logins and extensions. Websites are NOT rendered in an embedded Firefox widget. The browser window is maximized normally, with a normal close button. Closing its tracked session restores Millitop.
- Local editable/addable URL apps, Emby/Jellyfin name/URL/icon/show-on-Home overrides and reset-to-default actions, plus read-only managed apps assigned by the backend.
- Home | Files | DVR | Account | Gallery | Updates. Account shows device software update availability; Updates remains the support-message inbox. The sample billing UI is removed. Settings is a gear in the header.
- Actual Gallery/Family moments folder selection, per-profile persisted preferences, photo/video library scan, previews, browse-all grid and slideshow. Slideshow supports photo interval, videos, video sound, shuffle, repeat, previous/next, pause and keyboard controls. Missing/unplayable files produce errors; automatic skips stop if no item works.

## Browser setup and limitations
Desktop Firefox must already be installed. Use Settings > Check Firefox or choose its signed firefox.exe. The helper requires Mozilla-signed Firefox and will not launch arbitrary executables or silently fall back to WebView2. Install Firefox normally from Mozilla if it is missing; the feature does not silently install it or change the Windows default browser.

Open Settings > Manage Firefox extensions for the current household profile. Use the uBlock Origin listing button to open Mozilla Add-ons; approve installation in Firefox. Existing personal Firefox or old WebView2 cookies/extensions are not copied. You must sign in to sites again and install desired extensions separately in each managed profile. Firefox Sync can change what profiles share if you deliberately configure it; the app does not turn Sync on.

The helper uses normal PowerShell launch, -no-remote and an app-owned profile directory. It tracks the launched Firefox process tree instead of all personal Firefox windows. Repeated launches are blocked while its session is open. The app is minimized only after an owned visible window is confirmed. It does not close or kill personal Firefox. Unknown startup/closure leaves the update guard raised; close the managed Firefox window and quit/reopen Millitop before retrying. This behavior needs a real Windows/Firefox pilot; no browser session was launched by the assistant.

Extensions cannot be guaranteed to block every advertisement, and content blocking can break sites. Configure trusted signed extensions and site exceptions through Firefox. Browser windows are not DRM/ad-block guarantees.

## Settings and remote apps
Local app settings are per Millitop profile in SharedPreferences. Native VLC/IPTVnator installations are unchanged. Removing a URL app does not erase Firefox browsing data. Managed apps are labeled and read-only on the device; edit them in the dashboard. The backend protocol/route is POST /api/device/web-apps using the existing enrolled-device credential. No public/global app catalog is exposed.

The app syncs managed entries at startup and every five minutes. Device/server changes use a separate hashed connection namespace. Cached managed entries expire after 24 hours; revoked credentials hide them. Clicking a managed tile requires a fresh successful sync and uses the current enabled/assigned definition. The backend does not automatically open browsers. Local URL apps remain independent of admin connectivity.

URL validation permits HTTPS, plus HTTP for private/local IPs and .local/.lan/localhost names; rejects executable schemes, embedded credentials and obvious token/password query parameters. Sign in within Firefox. Icons are built-in assets/fallbacks; no server-side arbitrary favicon fetching is added.

## Gallery behavior
Choose up to ten existing normal library roots, or add a family folder (also becomes a Files shortcut). Choose whether to include subfolders and videos. Scanning is bounded to 2,000 media items, 200 directories and a time budget; limited/failed scans show warnings. Windows account permissions govern local/UNC access; this is not a profile filesystem security boundary. Files are not uploaded or deleted.

Image previews and slides use the existing library path-boundary checks and image limits. Native video playback reuses the existing media_kit dependencies. No new native media package is installed by this patch. The earlier native-library licensing/codec review still applies. Slideshow video playback and browser sessions keep the existing media-active update guard raised until native closure is confirmed. A failed cleanup requires quitting/reopening, not an unsafe claim that playback has stopped.

Photo auto-advance begins when the image frame is ready; videos advance after completion. Videos are muted by default unless enabled in settings. Auto-skip is bounded when media fails. This is not an unlimited recursive NAS index or cloud photo service. The supported Gallery entry points are the Gallery tab, Family moments > Open gallery, and Settings. Slideshow controls remain visible for reliable mouse/keyboard access.

## Account updates and safety
Account queries the existing authenticated update-check API, compares to the installed version, and rechecks the offered assignment before calling the existing signed installer flow. It is not a list of all administrator releases. Deferral of the banner does not prevent an explicit manual Account check. The updater install() implementation, native worker, bootstrap, release signature key and update-launch helper are preserved. New public account methods are added outside the proven installer body. No backend migration or privilege change is included in this client patch.

## Apply and release
Run the supplied installer on the development PC. It refuses to modify source during an unfinished or concurrently running release. Source must match the supplied 21:34 client export. It backs up changed files, adds modules/helper assets, updates notes and raises the configured version to at least 1.4.0. It runs PowerShell syntax checks, dart format, flutter analyze and all tests. It does NOT run a second standalone native build.

Passing -Release explicitly invokes release.cmd after checks pass and the source-edit lock is released. That pipeline performs the single Windows native build/Inno packaging/sign/publication/paused registration. It assigns no devices. If checks fail, stop and provide diagnostics; -RetryChecks retries the installed patch's checks without overwriting source. No keys or saved credentials are included in this source package.

## Pilot acceptance
1. Verify the update applies, startup is verified and pairing/profiles/Files/DVR still work.
2. Confirm navigation mapping; Account offers only this device's eligible software update; Updates contains support messages, not fake billing.
3. Open Emby/Jellyfin in Firefox, install a trusted blocker via this profile's add-ons page, sign in, close its window, and verify automatic return. Ensure an unrelated personal Firefox window is neither closed nor incorrectly tracked.
4. Edit a built-in URL/name, add/hide/remove a local URL app, reset a built-in; verify per-profile separation and gear actions.
5. Create/enable/assign a managed app in the dashboard, sync, open it, then disable its assignment and sync; confirm it disappears and cannot launch from stale data.
6. Select a family folder, preview photos, play photo/video slideshows, pause/resume, next/previous, repeat/shuffle, change sound/time, exit and reopen. Settings should persist and profiles should not mix.
7. Test offline/removed roots and an unsupported or damaged video. Back/Quit must remain recoverable; updates must remain blocked until active media closes safely.

Generated source has structural checks, not a local Flutter/Windows execution certification. Unit/widget tests deliberately use fake file/network providers for GUI fixtures; native Firefox and video lifecycle require the supervised real-device pilot before wider rollout.
