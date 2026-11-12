## v4.8.6

- Allow archived-package rollback without DNS, internet, GitHub checks or script self-update, including when `SelfUpdate=1` and `-m` are set.
- Defer TERM/INT/HUP cancellation while a tracked package operation completes, then restore the original Plex running/stopped state before releasing the updater lock.
- Refuse installation when DSM service-state queries fail or report diagnostic errors, rather than interpreting an error as a stopped service.
- Cover offline rollback, interruption during stop/install, repeated signals, competing invocations, launch/PID assignment races and ambiguous DSM status responses with isolated regression tests.
- Use unpredictable temporary files for GitHub response headers and remove a dead token-masking variable that broke ShellCheck.

### Updating

Automatic script updates require `SelfUpdate=1` and respect `MinimumAge`. The new script takes effect on the following run. Manual deployment can replace only `syno.plexupdate.sh`; preserve `config.ini` and `Archive`.

### Safety and verification

- Independent review passed. All 17 regression tests pass using mocked Synology/network commands; Bash syntax and GitHub CI checks pass.
- Live Plex package installation and rollback have not been exercised as part of this release.
- SIGKILL and power loss cannot run cleanup traps. A hung package operation intentionally retains the updater lock; inspect DSM before intervening. Work that DSM delegates beyond the lifetime of its CLI is outside Bash's guarantees.
- Ambiguous service-state responses abort without stopping or installing Plex; no guessed restoration state is used.
- Retention policy, download timeout handling, HTTP health checks and legacy success exit-status semantics are unchanged.

Release notes prepared by JARVIS, Agustin's AI assistant.

## v4.8.3

- Prevent concurrent updater runs from removing each other's lock or truncating active logs.
- Keep Plex tokens out of debug traces and restrict log permissions.
- Require successful installation and restart commands before reporting an update or rollback as successful.
- Select the highest archived version older than the installed version for rollback, even when only one older package exists.
- Preserve archived packages during rollback and return a failure status when rollback fails.
- Validate numeric configuration and prevent invalid release dates from bypassing minimum-age checks.
- Reject empty or syntactically invalid self-update downloads.
- Add isolated regression tests and CI validation.

### Updating

Existing installations using this fork discover this release through the normal scheduled run.
Automatic script updates require `SelfUpdate=1` in `config.ini` and respect `MinimumAge`
(default: 7 days). To bypass the age check for this run, use `-f`; this also bypasses
the Plex package age check. The updated script takes effect on the following run.

### Operational notes

The new lock directory is `/tmp/syno.plexupdate.lock.d`. Normal exits and termination
signals release it. After an uncatchable kill, verify that no updater is running
before manually removing that directory. Live installation on DSM has not been tested
as part of this release; regression tests use mocked Synology commands.
