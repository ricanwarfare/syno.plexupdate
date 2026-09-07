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
