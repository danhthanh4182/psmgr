# Privacy Policy

PSManager is dedicated to transparent, local PowerShell environment management.

## Zero Telemetry & Privacy
- **No telemetry:** PSManager has no analytics, tracking, crash reporting or background data collection.
- **Local profile management:** profile parsing, symlinking and module provisioning run entirely on the local machine.
- **Network calls:**
  - **Automatic update check:** at most once every six hours PSManager requests the public GitHub release metadata for this project (one HTTPS request; the response is cached locally for six hours). It sends no identifiers, no usage data and no configuration. Disable it with `PSMGR_DISABLE_UPDATE_CHECK=1`; the UI then shows the cached status as "disabled".
  - `psmgr update-app` / `install.ps1` download the published, digest-verified installer only when you run them.
  - `psmgr backup-cloud` uploads the profile archive to the private GitHub repository **you configure** (`cloudRepo` / `PSMGR_CLOUD_REPO`). Nothing is uploaded unless you run it, and it refuses the PSManager deploy repository.
  - Credentials stay with the `gh` CLI or the environment variable you set; PSManager never stores them.
