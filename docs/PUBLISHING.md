# Publishing this repository (`danhthanh4182/psmgr`)

**Status: completed 2026-11-14** — the repository is public and GitHub Pages is live at
`https://<owner>.github.io/psmgr/`. Keep this file as the checklist for any future flip (a fork,
or if the repository is ever made private again): a public repo exposes the git history **and
every release asset**, and some app features can accidentally push personal data into it.

Known residual: unreachable pre-rewrite commits (`e4ee31e`, `064521f`) are still fetchable by
SHA until GitHub Support purges them; request that purge if the exposure matters.

---

## 0. What must stay private

| Data | Where it lives today | Rule |
|---|---|---|
| Live PowerShell profiles + `starship.toml` | user machine, `%USERPROFILE%\Documents\…` | never commit; sync through a **private** payload repo |
| Profile backups (`profile_backup_*.zip[.enc]`) | your **data** repo (never this one) | decrypt or purge anything left in this repo's Releases |
| `local.ps1` machine overrides, tokens | machine only, gitignored | never commit |
| Signing material (`certs/`, `*.pfx`) | gitignored | never commit |

`templates/profiles/master_profile.ps1` and `templates/manifest.default.json` are generic
templates and are safe to publish.

---

## 1. Purge or migrate any legacy backup releases (conditional)

Historical note: this repo once carried eight `Profile Backup …` releases, one of them a
plaintext archive. A 2026-11 audit (`gh release list`, `gh release view`) found **only** the
application release `v1.7.3` with build assets, so the purge below is a **check**, not a known
cleanup. Re-run it before publishing — an old draft/asset can still reappear if `backup-cloud`
was ever pointed back at this repo (now impossible: the guard refuses it unconditionally).

```powershell
# Audit first (asset names end in .zip = plaintext, .zip.enc = encrypted)
gh release list --repo danhthanh4182/psmgr --limit 50
foreach ($tag in (gh release list --repo danhthanh4182/psmgr --limit 50 --json tagName --jq '.[].tagName' | Select-String 'profile-backup')) {
    "$tag :: " + (gh release view $tag --repo danhthanh4182/psmgr --json assets --jq '[.assets[].name] | join(",")')
}
```

Option A — delete (local copies in `backups/` remain):

```powershell
foreach ($tag in (gh release list --repo danhthanh4182/psmgr --limit 50 --json tagName --jq '.[].tagName' | Select-String 'profile-backup')) {
    gh release delete $tag --repo danhthanh4182/psmgr --yes --cleanup-tag
}
```

Option B — migrate to a private repo first:

```powershell
gh repo create danhthanh4182/psmgr-backups --private --description "PSManager profile backups"
$dir = Join-Path $env:TEMP 'psmgr-backup-migrate'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
foreach ($tag in (gh release list --repo danhthanh4182/psmgr --limit 50 --json tagName --jq '.[].tagName' | Select-String 'profile-backup')) {
    gh release download $tag --repo danhthanh4182/psmgr --dir $dir --clobber
    gh release create $tag (Get-ChildItem -LiteralPath $dir -File | ForEach-Object FullName) `
        --repo danhthanh4182/psmgr-backups --title "Profile Backup $tag" --notes "Migrated from danhthanh4182/psmgr"
    gh release delete $tag --repo danhthanh4182/psmgr --yes --cleanup-tag
    Remove-Item -LiteralPath $dir -Recurse -Force
}
```

Verify: `gh release list --repo danhthanh4182/psmgr` shows only app releases (`vX.Y.Z`).

---

## 2. Keep the payload in its own private repo

The engine (this repo) and the payload (dotfiles) are separate layers by design; publishing the
engine must not publish the payload.

```powershell
gh repo create <your-account>/dotfiles --private --description "PSManager payload (private)"
```

- Put `manifest.json`, `profiles/master_profile.ps1` (your real one), `configs/starship.toml`
  and a gitignored `local.ps1` in `<your-account>/dotfiles`.
- Run sync with that payload, e.g. `psmgr sync -Manifest <path>\dotfiles\manifest.json`
  (or clone it to `~/.dotfiles` and use the default lookup).
- Never run `psmgr adopt` with the app repo as payload root: `Adopt-PSManagerProfiles`
  (= `Import-PSManagerProfiles`, `modules/Sync/SyncEngine.ps1:269`) copies your live profile
  **into** `profiles/master_profile.ps1`; in this repo that file is tracked, so the next commit
  would publish your profile. Run `adopt` only inside the private payload repo.

---

## 3. Pin cloud backups away from this repo

`Get-DefaultBackupRepo` (`modules/Sync/Backup.ps1`) resolves `$env:PSMGR_CLOUD_REPO` →
`config.json` `cloudRepo` → the clone's `git remote origin` → `gh repo view`. The last two
**skip this repository**, so a fresh clone of the app never targets it: backups hold personal
data, and after the flip that would publish it to a public repo.

`Publish-PSManagerCloudBackup` additionally normalizes every target and refuses
`danhthanh4182/psmgr` **unconditionally**: the deploy repository (code + app releases) and the
user's data repository (profile backups) are always two separate repositories, whatever the
visibility. `-Repo`, `cloudRepo` and `PSMGR_CLOUD_REPO` cannot bypass this.

```powershell
psmgr set-cloud-repo danhthanh4182/psmgr-backups   # persists cloudRepo, already guarded
```

Encryption is skipped for non-interactive runs (`ps-manager.ps1` only prompts when standard
input is a console), so `psmgr backup-cloud` from a script uploads a **plaintext** archive. Set
the target to a private repository *now*, not after the flip.

Credentials: `backup-cloud` never stores a token. Precedence is the GUI/TUI token field or `-Token`,
then `PSMGR_CLOUD_TOKEN`, then `GH_TOKEN` / `GITHUB_TOKEN`, then the `gh` CLI login. A fine-grained
PAT limited to the single backups repository with `Contents: read and write` is enough, and a
per-call token leaves the global `gh` login untouched.

Release hygiene: `backup-cloud` creates `profile-backup-<stamp>` releases in the **data**
repository, never here. `Get-PSManagerUpdateStatus` still pages through `/releases` and picks the
highest semantic tag (`Select-PSManagerRelease`), ignoring backup, draft and prerelease tags, so a
stray non-semver release in the app repo cannot break update checks. Do not rename app releases
away from `vX.Y.Z`, or they will be skipped as well.

---

## 4. Scrub identity leftovers

Verified literal hits for the Windows user name in the current tree (replace every one with a
placeholder such as `C:\Users\<user>` before flipping):

| File | What it shows |
|---|---|
| `CHANGELOG.md` (portable-paths entry) | a developer `C:\Users\<user>\tools\ps-manager` path |
| `docs/ui-ux/omp/discovery.md` (2 places) | the same developer path |
| `tests/harness.ps1` (`$Script:ROOT_DIR` fallback) | the same developer path |
| `docs/ui-ux/shots/after/gui-live-logs.png` | **removed** — its activity log rendered `C:\Users\<user>\…` and a worktree name; re-capture with an empty log if the shot is needed again |
| `docs/PUBLISHING.md` (this file) | must stay placeholder-only |

Also audit **every** tracked screenshot, not just the landing-page copies: `docs/ui-ux/shots/**`
(`before/`, `after/`, the 1280/1920/2560 captures) may render paths, profile contents or the log
pane. Open each one, or exclude the directory from the public history.

- `PSManager.psd1` `Author`, `build/PSManager.Builder.psm1` author/company metadata and the MIT
  `LICENSE` copyright are intentional public attribution.
- Commit **author identity** becomes public too:
  `git log --format='%an <%ae>' --all | Sort-Object -Unique`. If a personal address appears,
  rewrite it (filter-repo + mailmap to a GitHub `noreply` address) while the repo is private.
- Issues and pull requests also turn public with the repo: `gh issue list --repo danhthanh4182/psmgr --state all`
  and `gh pr list --repo danhthanh4182/psmgr --state all`; delete or redact anything that quotes private data.
- If the user name must not appear in **history**, rewrite it before publishing
  (`git filter-repo --replace-text replacements.txt` on a mirror clone), then force-push. Do this
  only while the repo is private, and re-run the full test suite afterwards.

---

## 5. Scan history, not just HEAD

The harness only lints the working tree. Before flipping:

```powershell
git log --all -p -S "C:\Users\" | Select-String '^commit ' | Measure-Object
git log --all -p -S "ghp_" | Select-String '^commit ' | Measure-Object
git log --all -p -S "github_pat_" | Select-String '^commit ' | Measure-Object
git log --all -p -S "PSMGR_GITHUB_TOKEN" | Select-String '^commit ' | Measure-Object
git log --all --diff-filter=A --name-only | Select-String -Pattern 'local\.ps1|certs/|\.pfx$|gui_state\.json|backups/'
```

Any hit that is not a documentation example means: treat the value as leaked, **rotate it**, and
scrub it from history while still private.

**Branches are published too, not just `main`.** A public repo exposes every pushed branch and
tag. Verify what GitHub actually has before flipping:

```powershell
git ls-remote --heads origin        # only 'main' was pushed as of the 2026-11 audit
git ls-remote --tags origin
```

Delete stale branches (`git push origin --delete <branch>`) while the repo is private; local-only
branches that were never pushed cannot leak. Re-run the scans above with `--all` afterwards.

**Screenshots carry PII.** `gui-live-logs.png` was removed for this reason (its activity log rendered a
machine path). Any new capture must start with a cleared log; a text-only grep cannot catch it.

**Actions metadata is public too.** Run logs, artifacts and caches are not private just because
the repo was: purge them (a build log that echoed a local path or an environment dump is enough).

```powershell
gh run list --repo danhthanh4182/psmgr --limit 100
gh api repos/danhthanh4182/psmgr/actions/artifacts --paginate --jq '.artifacts[] | .name'
gh cache delete --all --repo danhthanh4182/psmgr
```

---

## 6. Flip visibility

```powershell
gh repo edit danhthanh4182/psmgr --visibility public --accept-visibility-change-consequences
```

---

## 7. After the flip

1. **Installers**: `irm https://raw.githubusercontent.com/danhthanh4182/psmgr/main/install.ps1 | iex` now
   works anonymously; verify on a clean profile.
2. **Update notifications**: `psmgr update-check` no longer needs a token for this repo; confirm
   `Status = Up to date` without `PSMGR_GITHUB_TOKEN`. `PSMGR_GITHUB_TOKEN` stays supported (rate
   limits) but is optional.
3. **Actions**: secrets are not exposed by the flip, but re-review `settings/secrets` (signing
   certificate, any site token) and delete what is unused. Enable **secret scanning**, push
   protection and Dependabot alerts.
4. **Landing page**: enable Pages with source *GitHub Actions*, set repository variable
   `PSMGR_PAGES_ENABLED=true`, run `PSManager Landing Page`, then confirm
   `https://danhthanh4182.github.io/psmgr/` returns 200 and the install tabs work anonymously.
5. **Branch protection**: require `ci` on `main` (and the `Run-Tests` gate) before accepting
   outside pull requests.
6. Re-check release assets once more: `gh release view v<latest> --repo danhthanh4182/psmgr --json assets`.

---

## Rollback

`gh repo edit danhthanh4182/psmgr --visibility private` hides the repo again, but does **not** retract
forks, clones, caches, or indexed copies already made while it was public. Treat a public flip as
permanent.
