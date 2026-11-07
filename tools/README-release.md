# Millitop TV release pipeline

## One-time installation
Run the installer on the development PC as the Windows user who owns the existing signing key (currently the development account). Do not move or regenerate that key. The installer installs project-owned scripts and copies the already-trusted Microsoft prerequisite installers into installer/prerequisites. No server deployment, sign-in, release build, publication, or device assignment is performed by installation.

The installer runs syntax validation and offline self-tests. It does not edit lib/, assets/, the updater or the signing key. Keep tools/, release.cmd, tools/release-notes.md and tools/release.config.json with the project. Do not commit .release/.

## Android sideload and corresponding source

**Required paired deployment:** every dashboard Windows release must include an
Android APK with the same version/build. Build and validate Android first; the
existing Windows pipeline below handles only the Windows portion. A deployment
is not complete until both public downloads are verified and the deployed
dashboard exposes the matching APK in Quick downloads. Report either-platform
failures as a blocked paired deployment, not a successful Windows-only release.

Android builds use the existing development keystore only when explicitly approved
for sideload testing. Keep the current package identity/signing key for compatible
updates; do not label this as production/store signing. Build ARM32 and ARM64 for
phones and Android TV (the universal APK also includes x86_64). Publish APKs in the dashboard's standalone download panel,
not as Windows installer update assignments.

Before distributing the GPLv3 PsTube-derived application, package the corresponding
source with `tools\package-release-source.ps1 -Version <version> -Build <build>`.
The ZIP includes the license, README build instructions and a per-file hash manifest,
including the local engine package. It excludes SDK paths, environment files,
keystores and generated caches. Existing source ZIPs cannot be overwritten with
different contents. Publish the ZIP next to the binaries and verify public hashes.
Run `tools\test-release-source.ps1` to verify archive/fingerprint behavior.

The Windows fingerprint covers Android and local `third_party` source as well.
Do not modify source or build Android concurrently while the Windows pipeline runs.

## Dashboard credential setup (explicit, once)
From the project root:

    .\release.cmd -ConfigureDashboardCredential

Enter a dashboard administrator account in the Windows credential prompt. The pipeline tests /api/login and authenticated GET /api/admin/releases. Type SAVE only if you consent to storing the credential for future release runs. The password is encrypted with Windows DPAPI in the current user's LocalAppData, with a restricted folder ACL. The username is not encrypted by CLIXML. No credentials or access tokens are written to the project, logs or command-line arguments. HTTPS requests necessarily contain the password transiently in process memory during sign-in.

Saving an administrator credential is a security tradeoff: programs running as that Windows user can use it. Protect that account and workstation. Use a dedicated authorized publishing account if appropriate; the current API uses existing dashboard administrator permissions, not a new restricted publisher role. Rotating/revoking this credential can require setup again. DPAPI binds it to this user and machine. Do not run the pipeline as SYSTEM or another Windows account. SSH authentication must already work noninteractively with the known millitop-host alias; host-key verification is not disabled.

If you do not want to store a dashboard password, run from PowerShell and provide it only for that invocation:

    .\tools\release.ps1 -DashboardCredential (Get-Credential)

This prompts each run instead of providing unattended registration.

Remove the saved dashboard credential without touching the signing key:

    .\release.cmd -ForgetDashboardCredential

## Normal release operation

    .\release.cmd

Default version is configured in release.config.json. Build numbers start at 13 and advance beyond both the registered build high-water mark and local reserved/failed runs. Symlinked application/tool sources outside generated directories are rejected; external path dependencies require a fingerprint review. The current working tree is built, including uncommitted changes; commit/review changes according to your own policy. Set meaningful release notes in tools/release-notes.md before the next release. To deliberately bump the version:

    .\release.cmd -Version 1.2.3 -Notes "Release notes"

Also update tools/release.config.json for subsequent default invocations of the new version. It contains public settings/tool paths, not secrets. Normal source changes with the same version produce a new higher build.

Stages:
1. Validate saved administrator access, API schema, existing signing key and noninteractive SSH.
2. Resolve dependencies and reserve a local build under an exclusive project lock.
3. Run existing builder analysis, tests, Windows build and Inno Setup exactly once for that run.
4. Seal the installer hash, sign with the existing pinned ECDSA key and verify signature/tamper rejection.
5. Publish immutable files through SSH. Existing identical remote pairs are reused; conflicts/partial pairs stop rather than overwrite.
6. Download the full installer and envelope from the public HTTPS URLs and check their exact hashes and size.
7. Register metadata through POST /api/admin/releases. Confirm it with a fresh GET and verify all immutable fields.
8. Print RELEASE_READY_FOR_ASSIGNMENT and save .release/latest-release.json.

Releases are registered paused. The pipeline NEVER assigns devices, enables/disables releases, redeploys the dashboard, writes SQL or exports/regenerates the private signing key. In the dashboard, choose the release/device and enable your intended pilot as part of deployment approval, then verify installation/startup. Application update signing is NOT Windows Authenticode signing or proof of clean-machine compatibility.

## Re-running / recovery
Run the same command again after a transient failure. Unchanged pending inputs resume the journal, without rebuilding or re-signing a completed artifact. A fully completed unchanged run is recognized in the registry and is not published twice. Remote artifacts already finalized are reused after hash verification; public downloads are rechecked when resuming publication. A partial staging upload may need retransmission.

If source/toolchain changed while an unfinished run exists, the command stops rather than silently shipping old code or reusing a reserved build:

    .\release.cmd -Resume

explicitly finishes the existing immutable artifact. Source must still match if compilation has not completed. To abandon an unfinished run and reserve a fresh build for changed source:

    .\release.cmd -NewRelease

Neither option deletes old journals or published files. Failed/reserved build numbers are not reused. A lost build receipt after a crash can require rebuilding before signing; once a completed build receipt is present it is reused. Missing/corrupt receipts, conflicting metadata, unexpected API schemas, mismatched signatures or modified binaries stop the run. Existing registered release metadata and enable states are never rewritten by this pipeline. Another workstation can still race for a build number; the registry conflict check stops mismatched metadata. The exclusive local lock protects this project, not every workstation globally.

## Logs and checks
Per-run logs, immutable plan, stage state and build receipt are in .release/runs/<run>/. Tokens/passwords are not included. Do not add broad Start-Transcript around authentication or run with HTTP tracing/verbose secret capture. A local source fingerprint includes application/native sources, lockfile, assets, tools, prerequisites and the Flutter toolchain identity. Source edits during compilation stop signing/publication.

    .\release.cmd -SelfTest

runs offline safety tests only. It does not access production credentials, keys, network or devices. Bundled helper integrity is checked before release execution. PowerShell child helpers run normally, return explicit exit codes and are not launched with Dart detached modes.

The first actual release remains a supervised pilot. Neither generated code nor successful offline tests establish production readiness. If backend authentication or release-list fields differ from the supplied source, preflight fails before building; inspect the current handler instead of bypassing authorization.
