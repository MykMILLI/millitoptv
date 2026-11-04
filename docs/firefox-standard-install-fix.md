# Firefox provisioning installation correction

Replaces the failed /ExtractDir execution with the same Mozilla silent-install method verified on the test PC. It targets the app-owned media/payments runtime directory and disables desktop/Start menu/taskbar/private-browsing shortcuts, maintenance service and default-browser agent. It does not request a Windows default-browser change. A normal Firefox installation can register itself as an installed application; this is no longer an extraction-only deployment.

Uses System.Diagnostics.Process directly, an explicit bounded wait and the actual exit code. Exit 3010 asks for a Windows restart; it is not falsely treated as browser readiness. Exit 0 must still produce a Mozilla-signed firefox.exe plus xul.dll and application.ini. Signature validation, cached installer checks, required extension policies, per-profile browser data, readiness checks, first-use consent, clean payment-purpose separation and existing-session guards remain.

This source correction does not reinstall anything on the development PC or target PC while patching. It changes the helper bundled with the next Millitop release. The test PC's successfully installed signed managed Firefox is detected and reused; it must not be uninstalled or deleted to test the patch. A separate fresh Windows user/test device with no managed runtime is needed for the first-use installer pilot.

The installer backs up the source outside the project, parses the native helper, runs focused contract tests, Flutter analysis and all tests. -Release then invokes the existing one-build/sign/publish/paused-registration pipeline. It neither redeploys the backend nor changes release mounts or signing keys. Version advances to at least 1.4.2; the build counter is automatic. -RetryChecks reruns checks without replacing source after a targeted fix.

This package does not implement Square customer mapping, invoices, payments, projects or billing UI. Those remain the next backend/client stage; no fake data or live payment operation is added. No further source export is needed merely to validate this provisioning fix.

Validated by generated-source checks and the reported manual installation test, not by a Windows execution in the assistant environment. Contract tests verify configuration strings/guards only, not actual installation. Real first-use and extension tests are still required.
