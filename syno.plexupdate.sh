#!/bin/bash
# shellcheck disable=SC2154,SC2181
# shellcheck source=/dev/null
#
# A script to automagically update Plex Media Server on Synology NAS
# This must be run as root to natively control running services
#
# Author @michealespinola https://github.com/michealespinola/syno.plexupdate
# Fork maintained by @ricanwarfare https://github.com/ricanwarfare/syno.plexupdate
#
# Original update concept based on: https://github.com/martinorob/plexupdate
#
# Example Synology DSM Scheduled Task type 'user-defined script': 
# bash /volume1/homes/admin/scripts/bash/plex/syno.plexupdate.sh

# SCRAPE SCRIPT PATH INFO
SrceFllPth=$(readlink -f "${BASH_SOURCE[0]}")
SrceFolder=$(dirname "$SrceFllPth")
SrceFileNm=${SrceFllPth##*/}

# ACQUIRE AN ATOMIC LOCK BEFORE OPENING (AND TRUNCATING) LOG FILES.
# Never remove another process's lock, including when acquisition fails.
umask 077
LOCKDIR="/tmp/syno.plexupdate.lock.d"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  printf ' %s\n' "* Another instance may be running. If no updater is running, remove $LOCKDIR and retry."
  exit 1
fi

# ── SECRET REDACTION ────────────────────────────────────────────────────────
# The token is handled under `set +x` guards, but a guard only protects the
# lines that have one: the whole script runs with `set -x`, so any future edit
# that touches the variable outside a guarded region writes it in clear to the
# .debug log. Rather than trust every present and future author to remember,
# scrub the known secret out of both logs on the way out. This is the safety
# net, not the primary control.
PlexOToken=""
redact_secrets_from_logs() {
  [ -n "${SrceFllPth:-}" ] || return 0
  for _logf in "$SrceFllPth.debug" "$SrceFllPth.log"; do
    [ -s "$_logf" ] || continue
    # Token value, wherever it appeared.
    if [ -n "${PlexOToken:-}" ] && grep -qF -- "$PlexOToken" "$_logf" 2>/dev/null; then
      grep -vF -- "$PlexOToken" "$_logf" > "$_logf.redacted" 2>/dev/null &&
        mv -f "$_logf.redacted" "$_logf"
      chmod 600 "$_logf" 2>/dev/null || true
    fi
    # Header form, in case only the header line survived.
    sed -i 's/\(X-Plex-Token: \)[^ "]*/\1****REDACTED****/g' "$_logf" 2>/dev/null || true
    rm -f "$_logf.redacted" 2>/dev/null || true
  done
  return 0
}

trap 'redact_secrets_from_logs; rmdir "$LOCKDIR" 2>/dev/null' EXIT
trap 'redact_secrets_from_logs; exit 130' INT
trap 'redact_secrets_from_logs; exit 143' TERM

# REDIRECT STDOUT TO TEE AND KEEP DEBUG OUTPUT PRIVATE.
chmod 600 "$SrceFllPth.log" "$SrceFllPth.debug" 2>/dev/null || true
exec > >(tee "$SrceFllPth.log") 2>"$SrceFllPth.debug"
set -uo pipefail
set -x

# SCRIPT VERSION
readonly SpuscrpVer=4.8.5
readonly MinDSMVers=7.0
# PRINT OUR GLORIOUS HEADER BECAUSE WE ARE FULL OF OURSELVES
printf "\n"
printf "%s\n" "SYNO.PLEX UPDATE SCRIPT v$SpuscrpVer for DSM 7"
printf "\n"

# HELPER: STRIP BUILD NUMBER FROM VERSION STRING (e.g. "1.32.0.6918-1234567" -> "1.32.0.6918")
strip_build_version() {
  printf '%s' "${1%%-*}"
}

# CHECK IF ROOT
if [ "$EUID" -ne "0" ]; then
  printf ' %s\n\n' "* This script MUST be run as root - exiting.."
  /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update task failed. Script was not run as root."}'
  printf "\n"
  exit 1
fi

ExitStatus=""

# CHECK IF DEFAULT CONFIG FILE EXISTS, IF NOT CREATE IT
create_or_update_config() {
  local ConfigFile="$1"
  if [ ! -f "$ConfigFile" ]; then
    printf ' %s\n\n' "* CONFIGURATION FILE (config.ini) IS MISSING, CREATING DEFAULT SETUP.."
    touch "$ConfigFile"
    ExitStatus=1
  fi
  # Function to add key-value pairs along with comments if not present
  add_config_with_comment() {
    local key="$1"
    local value="$2"
    local comment="$3"
    if ! grep -q "^$key=" "$ConfigFile"; then
      printf '%s\n' "$comment" >> "$ConfigFile"
      printf '%s\n' "$key=$value" >> "$ConfigFile"
    fi
  }
  # Default configurations
  add_config_with_comment "MinimumAge" "7"   "# A NEW UPDATE MUST BE THIS MANY DAYS OLD"
  add_config_with_comment "OldUpdates" "60"  "# PREVIOUSLY DOWNLOADED PACKAGES DELETED IF OLDER THAN THIS MANY DAYS"
  add_config_with_comment "NetTimeout" "900" "# NETWORK TIMEOUT IN SECONDS (900s = 15m)"
  add_config_with_comment "SelfUpdate" "0"   "# SCRIPT WILL SELF-UPDATE IF SET TO 1"
  add_config_with_comment "SkipAgeCheck" "0" "# BYPASS ALL MINIMUM AGE CHECKS IF SET TO 1"
}
create_or_update_config "$SrceFolder/config.ini"

# LOAD CONFIG FILE -- PARSED, NEVER EXECUTED
# `source`ing this file ran whatever it contained as root. The config sits next
# to the script, which is wherever the operator put it -- the documented
# install path in this very header is a user's home directory -- so anyone able
# to write config.ini, or to replace it (its containing directory's write bit
# is enough, since unlink is a property of the directory and not of the file),
# obtained arbitrary root execution on the NAS.
#
# Only the five known settings are read, each value is validated against the
# shape that setting actually accepts, and anything unrecognised is reported
# and ignored instead of run. A tampered config now degrades to "your setting
# was ignored", not to code execution.
load_config() {
  local ConfigFile="$1" line key value
  [ -f "$ConfigFile" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and comments.
    case "$line" in
      ''|\#*) continue ;;
    esac
    # Anything that is not KEY=VALUE is not a setting; never execute it.
    case "$line" in
      *=*) ;;
      *)
        printf ' %s\n' "* SECURITY: ignoring non-setting line in config.ini: ${line:0:60}"
        continue
        ;;
    esac

    key=${line%%=*}
    value=${line#*=}
    # Trim whitespace, then one layer of matching quotes.
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                                          -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")

    case "$key" in
      MinimumAge|OldUpdates|NetTimeout)
        if [[ $value =~ ^[0-9]+$ ]]; then
          printf -v "$key" '%s' "$value"
        else
          printf ' %s\n' "* SECURITY: ignoring non-numeric $key in config.ini: ${value:0:40}"
        fi
        ;;
      SelfUpdate)
        if [[ $value =~ ^[01]$ ]]; then
          printf -v "$key" '%s' "$value"
        else
          printf ' %s\n' "* SECURITY: ignoring invalid SelfUpdate in config.ini: ${value:0:40}"
        fi
        ;;
      SkipAgeCheck)
        if [[ $value =~ ^(0|1|true|false)$ ]]; then
          printf -v "$key" '%s' "$value"
        else
          printf ' %s\n' "* SECURITY: ignoring invalid SkipAgeCheck in config.ini: ${value:0:40}"
        fi
        ;;
      *)
        printf ' %s\n' "* SECURITY: ignoring unknown setting in config.ini: ${key:0:40}"
        ;;
    esac
  done < "$ConfigFile"
}
load_config "$SrceFolder/config.ini"

# SET DEFAULTS FOR ALL CONFIG VARIABLES
MinimumAge="${MinimumAge:-7}"
OldUpdates="${OldUpdates:-60}"
NetTimeout="${NetTimeout:-900}"
SelfUpdate="${SelfUpdate:-0}"
SkipAgeCheck="${SkipAgeCheck:-0}"
if [ "$SkipAgeCheck" = "1" ] || [ "$SkipAgeCheck" = "true" ]; then
  SkipAgeCheck=true
else
  SkipAgeCheck=false
fi

MasterUpdt=false
Rollback=false
UpdtChannl=""

# PRINT SCRIPT STATUS/DEBUG INFO
printf '%16s %s\n'                   "Script:" "$SrceFileNm"
printf '%16s %s\n'               "Script Dir:" "$(fold -w 72 -s     < <(printf '%s' "$SrceFolder") | sed '2,$s/^/                 /')"

# OVERRIDE SETTINGS WITH CLI OPTIONS
while getopts ":a:c:mrfh" opt; do
  case ${opt} in
    a) # SET MINIMUM AGE THRESHOLD (in days) for both script and Plex updates
      # Check if the value is numerical only
      if [[ $OPTARG =~ ^[0-9]+$ ]]; then
        MinimumAge=$OPTARG
        printf '%16s %s\n'         "Override:" "-a, Minimum age threshold set to $MinimumAge days"
      else
        printf '\n%16s %s\n\n'   "Bad Option:" "-a, requires a number value for minimum age in days"
        exit 1
      fi
      ;;
    c) # CHOOSE UPDATE CHANNEL
      case $OPTARG in
        p) UpdtChannl="0" # Public channel
          printf '%16s %s\n'       "Override:" "-c, Update Channel set to Public"
          ;;
        b) UpdtChannl="8" # Beta channel
          printf '%16s %s\n'       "Override:" "-c, Update Channel set to Beta"
          ;;
        *)
          printf '\n%16s %s\n\n' "Bad Option:" "-c, Requires either 'p' for Public or 'b' for Beta channels"
          exit 1
          ;;
      esac
      ;;
    m) # UPDATE TO MASTER BRANCH (NON-RELEASE)
      MasterUpdt=true
      printf '%16s %s\n'           "Override:" "-m, Forcing script update from Master branch"
      ;;
    r) # ROLLBACK TO PREVIOUS VERSION
      Rollback=true
      ;;
    f) # FORCE INSTALL - skip all age checks for both script and Plex updates
      SkipAgeCheck=true
      printf '%16s %s\n'           "Override:" "-f, Force mode - skipping all minimum age checks"
      ;;
    h) # HELP OPTION
      printf '\n%s\n\n'  "Usage: $SrceFileNm [-a #] [-c p|b] [-m] [-r] [-f] [-h]"
      printf ' %s\n'   "-a #: Set minimum age threshold in days (e.g. -a 14 for stricter, -a 0 for lenient)"
      printf ' %s\n'   "-c:   Override the update channel (p for Public, b for Beta)"
      printf ' %s\n'   "-m:   Update script from the master branch (non-release version)"
      printf ' %s\n'   "-r:   Rollback Plex to the previous installed version"
      printf ' %s\n'   "-f:   Force mode - bypass all minimum age checks for script and Plex updates"
      printf ' %s\n\n' "-h:   Display this help message"
      exit 0
      ;;
    \?) # INVALID OPTION
      printf '\n%16s %s\n\n'     "Bad Option:" "-$OPTARG, Invalid (-h for help)"
      exit 1
      ;;
    :) # MISSING ARGUMENT
      printf '\n%16s %s\n\n'     "Bad Option:" "-$OPTARG, Requires an argument (-h for help)"
      exit 1
      ;;
  esac
done

# Validate numeric settings before arithmetic, downloads, or archive cleanup.
for setting in MinimumAge OldUpdates NetTimeout; do
  value=${!setting}
  if [[ ! $value =~ ^[0-9]{1,9}$ ]]; then
    printf ' %s\n' "* Invalid $setting: expected a nonnegative integer (at most 9 digits)."
    exit 1
  fi
  printf -v "$setting" '%d' "$((10#$value))"
done
if [[ $SelfUpdate != 0 && $SelfUpdate != 1 ]]; then
  printf ' %s\n' '* Invalid SelfUpdate: expected 0 or 1.'
  exit 1
fi

# CHECK FOR BASIC INTERNET CONNECTIVITY
if nslookup one.one.one.one >/dev/null 2>&1; then
 #printf '\n %s\n\n' "* OK: DNS resolution works.."
  :
elif ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
  printf '\n %s\n\n' "* DNS resolution appears to be failing - exiting.."
  exit 1
else
  printf '\n %s\n\n' "* Internet appears to be down - exiting.."
  exit 1
fi

# CHECK IF SCRIPT IS ARCHIVED
if [ ! -d "$SrceFolder/Archive/Scripts" ]; then
  mkdir -p "$SrceFolder/Archive/Scripts"
fi
if [ ! -f "$SrceFolder/Archive/Scripts/syno.plexupdate.v$SpuscrpVer.sh" ]; then
  cp "$SrceFllPth" "$SrceFolder/Archive/Scripts/syno.plexupdate.v$SpuscrpVer.sh"
else
  if ! cmp -s "$SrceFllPth" "$SrceFolder/Archive/Scripts/syno.plexupdate.v$SpuscrpVer.sh"; then
    cp "$SrceFllPth" "$SrceFolder/Archive/Scripts/syno.plexupdate.v$SpuscrpVer.sh"
  fi
fi

# GET EPOCH TIMESTAMP FOR AGE CHECKS
TodaysDate=$(date +%s)

# SCRAPE GITHUB WEBSITE FOR LATEST INFO
GitHubRepo=ricanwarfare/syno.plexupdate
SpusNewVer=""
SpusApiRlm=""
SpusApiRlr=""
SpusApiMsg=""
SpusApiDoc=""
SpusRlDate=""
SpusRelAge=""
SpusDwnUrl=""
SpusRelDes=""
SpusHlpUrl=""
SpusDwnSha=""
SpusHeaders="/tmp/syno.plexupdate.gh_headers.$$"

if GitHubJson=$(curl -s -m "$NetTimeout" -D "$SpusHeaders" -L "https://api.github.com/repos/$GitHubRepo/releases?per_page=1"); then
  SpusApiRlm=$(grep -i '^x-ratelimit-limit:' "$SpusHeaders" 2>/dev/null | tr -d '\r' | awk '{print $2}')
  SpusApiRlr=$(grep -i '^x-ratelimit-remaining:' "$SpusHeaders" 2>/dev/null | tr -d '\r' | awk '{print $2}')
  rm -f "$SpusHeaders"

  eval "$(jq -r '
    if type == "array" and length > 0 then
      .[0] | (
        "SpusNewVer=" + ((.tag_name // "") | sub("^v"; "") | @sh) + "\n" +
        "SpusRlDate_Raw=" + ((.published_at // "") | @sh) + "\n" +
        "SpusRelDes=" + ((.body // "") | @sh)
      )
    elif type == "object" then
      "SpusApiMsg=" + ((.message // "") | @sh) + "\n" +
      "SpusApiDoc=" + ((.documentation_url // "") | @sh)
    else
      ""
    end
  ' <<< "$GitHubJson" 2>/dev/null)"

  if [ -n "${SpusNewVer:-}" ] && [ "$SpusNewVer" != "null" ]; then
    SpusRlDate=$(date --date "$SpusRlDate_Raw" +'%s' 2>/dev/null || echo "0")
    SpusRelAge=-1
    if [ "$SpusRlDate" -gt 0 ]; then
      SpusRelAge=$(((TodaysDate-SpusRlDate)/86400))
    fi
    if [ "$MasterUpdt" = "true" ]; then
      SpusDwnUrl=https://raw.githubusercontent.com/$GitHubRepo/master/syno.plexupdate.sh
      SpusRelDes=$'* Check GitHub for master branch commit messages and extended descriptions'
    else
      SpusDwnUrl=https://raw.githubusercontent.com/$GitHubRepo/v$SpusNewVer/syno.plexupdate.sh
    fi
    SpusHlpUrl=https://github.com/$GitHubRepo/issues
  else
    SpusNewVer=""
    if [ -z "${SpusApiMsg:-}" ]; then
      printf ' %s\n\n' "* NO RELEASES FOUND ON GITHUB REPO.."
    fi
    ExitStatus=1
  fi
else
  rm -f "$SpusHeaders"
  printf ' %s\n\n' "* UNABLE TO CHECK FOR LATEST VERSION OF SCRIPT.."
  ExitStatus=1
fi

# PRINT SCRIPT STATUS/DEBUG INFO
printf '%16s %s\n'      "Running Ver:" "$SpuscrpVer"

if [ -n "${SpusApiMsg:-}" ]; then
  printf "%16s %s\n" "GitHub API Msg:" "$(fold -w 72 -s     < <(printf '%s' "$SpusApiMsg") | sed '2,$s/^/                 /')"
  printf "%16s %s\n" "GitHub API Lmt:" "${SpusApiRlm:-0} connections per hour per IP"
  printf "%16s %s\n" "GitHub API Doc:" "$(fold -w 72 -s     < <(printf '%s' "$SpusApiDoc") | sed '2,$s/^/                 /')"
  ExitStatus=1
elif [ "$SpusNewVer" != "" ]; then
  printf '%16s %s\n'     "Online Ver:" "$SpusNewVer (attempts left ${SpusApiRlr:-0}/${SpusApiRlm:-0})"
  printf '%16s %s\n'       "Released:" "$(date --rfc-3339 seconds --date @"$SpusRlDate" 2>/dev/null || echo "$SpusRlDate") ($SpusRelAge+ days old)"
fi

# COMPARE SCRIPT VERSIONS
if [[ -n "$SpusNewVer" && "$SpusNewVer" != "null" ]]; then
  if /usr/bin/dpkg --compare-versions "$SpusNewVer" gt "$SpuscrpVer" || [[ "$MasterUpdt" == "true" ]]; then
    if [[ "$MasterUpdt" == "true" ]]; then
      printf '%17s%s\n' '' "* Updating from master branch!"
    else
      printf '%17s%s\n' '' "* Newer version found!"
    fi
    # DOWNLOAD AND INSTALL THE SCRIPT UPDATE
    if [ "$SelfUpdate" -eq 1 ]; then
      if [ "$SpusRelAge" -ge "$MinimumAge" ] || [ "$MasterUpdt" = "true" ] || [ "$SkipAgeCheck" = "true" ]; then
        printf "\n"
        printf "%s\n" "INSTALLING NEW SCRIPT:"
        printf "%s\n" "----------------------------------------"

        # RESOLVE THE EXPECTED BLOB SHA FROM THE API (not from the same download
        # we are about to trust). This script runs as root and replace-executes
        # itself, so a plain wget + mv -f means anyone able to answer for
        # raw.githubusercontent.com owns root on this NAS. Binding the download
        # to a git blob id fetched over the API turns "the bytes we happened to
        # receive" into "the bytes GitHub says are at that ref"; HTTPS alone
        # does not pin content across a CDN.
        SpusRefForSha="master"
        [ "$MasterUpdt" = "true" ] || SpusRefForSha="v$SpusNewVer"
        SpusDwnSha=$(curl -s -m "$NetTimeout" -L \
              "https://api.github.com/repos/$GitHubRepo/contents/syno.plexupdate.sh?ref=$SpusRefForSha" \
              2>/dev/null | jq -r '.sha // ""' 2>/dev/null)

        if [ -z "$SpusDwnSha" ] || [ "$SpusDwnSha" = "null" ]; then
          printf ' %s\n' "* SECURITY: could not resolve the expected blob SHA from the GitHub API."
          printf ' %s\n' "* Refusing to self-update an unverifiable script. Update manually from:"
          printf ' %s\n' "*   $SpusHlpUrl"
          ExitStatus=1
        elif ! /bin/wget -nv -T "$NetTimeout" -O "$SrceFolder/Archive/Scripts/$SrceFileNm" "$SpusDwnUrl" 2>&1; then
          printf '%17s%s\n' '' "* DOWNLOAD FAILED - skipping."
          /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Syno.Plex Update\n\nSelf-Update failed to download."}'
          ExitStatus=1
        elif [ ! -s "$SrceFolder/Archive/Scripts/$SrceFileNm" ] || ! bash -n "$SrceFolder/Archive/Scripts/$SrceFileNm"; then
          printf '%17s%s\n' '' "* DOWNLOADED FILE INVALID - skipping."
          rm -f "$SrceFolder/Archive/Scripts/$SrceFileNm"
          ExitStatus=1
        else
          # VERIFY CONTENT against the API-reported blob SHA-1. This is a git
          # object id, not a hash of the raw file bytes, so the git blob header
          # is part of the digest.
          _SpusGotSha=$( { printf 'blob %s\0' "$(wc -c < "$SrceFolder/Archive/Scripts/$SrceFileNm" | tr -d ' ')"; \
                           cat "$SrceFolder/Archive/Scripts/$SrceFileNm"; } | sha1sum | cut -d' ' -f1 )
          if [ "$_SpusGotSha" != "$SpusDwnSha" ]; then
            printf ' %s\n' "* SECURITY: downloaded script FAILED integrity verification."
            printf '%17s%s\n' '' "expected: $SpusDwnSha"
            printf '%17s%s\n' '' "got:      $_SpusGotSha"
            printf ' %s\n' "* Refusing to install; the file has been discarded."
            rm -f "$SrceFolder/Archive/Scripts/$SrceFileNm"
            /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Syno.Plex Update\n\nScript self-update FAILED integrity verification and was not installed. Investigate immediately."}'
            ExitStatus=1
          else
            # MOVE-OVERWRITE (not copy) so the running in-memory script is not corrupted.
            mv -f -v "$SrceFolder/Archive/Scripts/$SrceFileNm" "$SrceFolder/$SrceFileNm" 2>&1
            chmod +x "$SrceFolder/$SrceFileNm"
            printf "%s\n" "----------------------------------------"
            printf '%17s%s\n' '' "* Script update succeeded (integrity verified)!"
            /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Syno.Plex Update\n\nSelf-Update completed successfully"}'
            ExitStatus=1
            if [ -n "$SpusRelDes" ]; then
              # SHOW RELEASE NOTES
              printf "\n"
              printf "%s\n" "RELEASE NOTES:"
              printf "%s\n" "----------------------------------------"
              printf "%s\n" "$SpusRelDes"
              printf "%s\n" "----------------------------------------"
              printf "%s\n" "Report issues to: $SpusHlpUrl"
            fi
          fi
        fi
      else
        printf ' \n%s\n' "Script update is too new ($SpusRelAge days), requires $MinimumAge+ days - skipping.."
      fi
    fi
  else
    printf '%17s%s\n' '' "* No new version found."
  fi
fi
printf "\n"

# SCRAPE SYNOLOGY HARDWARE MODEL
if [ -f /proc/sys/kernel/syno_hw_version ]; then
  SynoHModel=$(< /proc/sys/kernel/syno_hw_version)
else
  SynoHModel="Synology NAS"
fi
# SCRAPE SYNOLOGY CPU ARCHITECTURE FAMILY
ArchFamily=$(uname --machine)

# FIXES FOR INCONSISTENT ARCHITECTURE MATCHES
[ "$ArchFamily" = "i686" ]   && ArchFamily=x86
[ "$ArchFamily" = "armv7l" ] && ArchFamily=armv7neon

# SCRAPE DSM VERSION AND CHECK COMPATIBILITY
DSMVersion=$(grep -i "productversion=" "/etc.defaults/VERSION" 2>/dev/null | cut -d"\"" -f 2)
if [ -z "$DSMVersion" ]; then
  DSMVersion="7.0"
fi

if /usr/bin/dpkg   --compare-versions "$DSMVersion" "ge" "5.2"   && /usr/bin/dpkg --compare-versions "$DSMVersion" "lt" "7"; then
  DSMplexNID="synology"
elif /usr/bin/dpkg --compare-versions "$DSMVersion" "ge" "7"     && /usr/bin/dpkg --compare-versions "$DSMVersion" "lt" "7.2.2"; then
  DSMplexNID="synology-dsm7"
elif /usr/bin/dpkg --compare-versions "$DSMVersion" "ge" "7.2.2"; then
  DSMplexNID="synology-dsm72"
else
  printf ' %s\n' "* Unsupported DSM version: $DSMVersion - exiting.."
  /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update task failed. No coinciding Plex version identified for this version of Synology DSM."}'
  printf "\n"
  exit 1
fi

# CHECK IF DSM 7
if /usr/bin/dpkg --compare-versions "$MinDSMVers" gt "$DSMVersion"; then
  printf ' %s\n' "* Syno.Plex Update requires DSM $MinDSMVers minimum to install - exiting.."
  /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update task failed. DSM not sufficient version."}'
  printf "\n"
  exit 1
fi
DSMVersion=$(grep -i "buildnumber="    "/etc.defaults/VERSION" 2>/dev/null | cut -d'"' -f 2 | { read -r build; [ -n "$build" ] && printf '%s-%s' "$DSMVersion" "$build" || printf '%s' "$DSMVersion"; })
DSMUpdateV=$(grep -i "smallfixnumber=" "/etc.defaults/VERSION" 2>/dev/null | cut -d'"' -f 2)
if [ -n "$DSMUpdateV" ]; then
  DSMVersion="$DSMVersion Update $DSMUpdateV"
fi

# SCRAPE CURRENTLY RUNNING PMS VERSION
RunVersion=$(/usr/syno/bin/synopkg version "PlexMediaServer" 2>/dev/null || echo "")
RunVersion=$(strip_build_version "$RunVersion")

# SCRAPE PMS FOLDER LOCATION AND CREATE ARCHIVED PACKAGES DIR W/OLD FILE CLEANUP
PlexFolder=$(readlink /var/packages/PlexMediaServer/shares/PlexMediaServer 2>/dev/null || echo "")
PlexFolder="$PlexFolder/AppData/Plex Media Server"
mkdir -p "$SrceFolder/Archive/Packages"

if [ -d "$PlexFolder/Updates" ]; then
  mv -f "$PlexFolder/Updates/"* "$SrceFolder/Archive/Packages/" 2>/dev/null
  if [ -n "$(find "$PlexFolder/Updates/" -prune -empty 2>/dev/null)" ]; then
    rmdir "$PlexFolder/Updates/"
  fi
fi

if [ "$Rollback" != "true" ] && [ -d "$SrceFolder/Archive/Packages" ]; then
  find "$SrceFolder/Archive/Packages" -type f -name "PlexMediaServer*.spk" -mtime +"$OldUpdates" -delete
fi

# SCRAPE PLEX ONLINE TOKEN WITHOUT WRITING IT TO THE DEBUG LOG
{ set +x; } 2>/dev/null
PlexOToken=$(grep -oP "PlexOnlineToken=\"\K[^\"]+"     "$PlexFolder/Preferences.xml" 2>/dev/null || echo "")
# No masked copy is kept: nothing in this script ever prints the token, and the
# `set +x` guards above (plus redact_secrets_from_logs at exit) are the controls
# that actually protect it. A dead `PlexOTokenMasked` variable only trips
# ShellCheck SC2034, which fails the lint job at the default `style` severity.
set -x
# SCRAPE PLEX SERVER UPDATE CHANNEL
PlexChannl=$(grep -oP "ButlerUpdateChannel=\"\K[^\"]+" "$PlexFolder/Preferences.xml" 2>/dev/null || echo "")
[ -n "$UpdtChannl" ] && PlexChannl="$UpdtChannl" # Override with command line option

# ROLLBACK FUNCTIONALITY
if [ "$Rollback" = "true" ]; then
  printf "\n%s\n" "ROLLBACK TO PREVIOUS VERSION:"
  printf "%s\n" "----------------------------------------"
  # Select the highest archived version below the installed version.
  # Read metadata as text; never execute a package's INFO file.
  PreviousPkg=""
  PreviousVersion=""
  for pkg in "$SrceFolder/Archive/Packages/"PlexMediaServer*.spk; do
    [ -f "$pkg" ] || continue
    PkgVersion=$(tar -xOf "$pkg" INFO 2>/dev/null | sed -n 's/^version="\([^"]*\)"$/\1/p')
    PkgVersion=$(strip_build_version "$PkgVersion")
    [[ $PkgVersion =~ ^[0-9]+(\.[0-9]+)+$ ]] || continue
    if [ -n "$RunVersion" ] && /usr/bin/dpkg --compare-versions "$PkgVersion" lt "$RunVersion"; then
      if [ -z "$PreviousVersion" ] || /usr/bin/dpkg --compare-versions "$PkgVersion" gt "$PreviousVersion"; then
        PreviousPkg=$pkg
        PreviousVersion=$PkgVersion
      fi
    fi
  done
  if [ -z "$PreviousPkg" ]; then
    printf ' %s\n' '* No archived version older than the installed version was found - cannot rollback'
    exit 1
  fi
  # Verify archive integrity before stopping Plex
  if ! tar -tf "$PreviousPkg" >/dev/null 2>&1; then
    printf ' %s\n' "* Previous package archive is corrupt or unreadable - cannot rollback"
    printf "%s\n" "----------------------------------------"
    /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update rollback failed. Previous package corrupted."}'
    exit 1
  fi
  printf '%16s %s\n' "Previous Package:" "$(basename "$PreviousPkg")"
  printf '%16s %s\n' "Current Version:" "$RunVersion"
  printf "\n%s\n"   "Stopping PlexMediaServer service (JSON):"
  InstallOK=true
  /usr/syno/bin/synopkg stop "PlexMediaServer" || exit 1
  printf "\n%s\n" "Installing previous package (JSON):"
  /usr/syno/bin/synopkg install "$PreviousPkg" | \
    jq -c '.results[] |= (
      if (.scripts // empty) | type == "array" then
        .scripts |= map(
          if .message then
            .message |= (
              gsub("<[^>]*>"; "")     # Strip HTML
              | split("\n")[0]        # Keep only the first real line
            )
          else . end
        )
      else .
      end
    )' || InstallOK=false
  printf "\n%s\n" "Starting PlexMediaServer service (JSON):"
  /usr/syno/bin/synopkg start "PlexMediaServer" || InstallOK=false
  printf "%s\n" "----------------------------------------"
  NowVersion=$(/usr/syno/bin/synopkg version "PlexMediaServer" 2>/dev/null || echo "")
  NowVersion=$(strip_build_version "$NowVersion")
  printf '%16s %s\n' "Rollback from:" "$RunVersion"
  printf '%16s %s'             "to:" "$NowVersion"
  if [ "$InstallOK" = true ] && [ -n "$NowVersion" ] && /usr/bin/dpkg --compare-versions "$PreviousVersion" eq "$NowVersion"; then
    printf ' %s\n' "succeeded!"
    /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update rollback completed successfully"}'
  else
    printf ' %s\n' "failed!"
    /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update rollback failed."}'
    exit 1
  fi
  exit 0
fi

if [ -z "$PlexChannl" ]; then
  # DEFAULT TO PUBLIC SERVER UPDATE CHANNEL IF NULL (NEVER SET) VALUE
  ChannlName=Public
  ChannelUrl="https://plex.tv/api/downloads/5.json"
else
  if [ "$PlexChannl" -eq "0" ]; then
    # PUBLIC SERVER UPDATE CHANNEL
    ChannlName=Public
    ChannelUrl="https://plex.tv/api/downloads/5.json"
  elif [ "$PlexChannl" -eq "8" ]; then
    # BETA SERVER UPDATE CHANNEL (REQUIRES PLEX PASS)
    { set +x; } 2>/dev/null
    if [ -z "$PlexOToken" ]; then
      printf ' %s\n' "Beta channel requires a Plex Online Token but none was found - exiting.."
      /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update task failed. Beta channel selected but no Plex Online Token found."}'
      printf "\n"
      exit 1
    fi
    set -x
    ChannlName=Beta
    ChannelUrl="https://plex.tv/api/downloads/5.json?channel=plexpass"
  else
    # REPORT ERROR IF UNRECOGNIZED CHANNEL SELECTION
    printf ' %s\n' "Unable to identify Server Update Channel (Public, Beta, etc) - exiting.."
    /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update task failed. Could not identify update channel (Public, Beta, etc)."}'
    printf "\n"
    exit 1
  fi
fi

# SCRAPE PLEX WEBSITE FOR UPDATE INFO
NewVerFull=""
NewVersion=""
NewVerDate=""
NewVerAddd=""
NewVerFixd=""
NewDwnlUrl=""
NewPackage=""
PackageAge=""
# DISABLE XTRACE TEMPORARILY TO PREVENT TOKEN LEAK IN DEBUG LOG
{ set +x; } 2>/dev/null
if [ -n "$PlexOToken" ]; then
  PlexTvJson=$(curl -s -m "$NetTimeout" -L -H "X-Plex-Token: $PlexOToken" "$ChannelUrl")
else
  PlexTvJson=$(curl -s -m "$NetTimeout" -L "$ChannelUrl")
fi
_curl_rc=$?
set -x

if [ "$_curl_rc" -eq "0" ] && [ -n "$PlexTvJson" ]; then
  eval "$(jq --arg DSMplexNID "$DSMplexNID" --arg ArchFamily "$ArchFamily" -r '
    (.nas[$DSMplexNID] // (.nas[]? | select(.id == $DSMplexNID))) as $target |
    if $target then
      "NewVerFull=" + (($target.version // "") | @sh) + "\n" +
      "NewVerDate=" + (($target.release_date // "") | tostring | @sh) + "\n" +
      "NewVerAddd=" + (($target.items_added // "") | @sh) + "\n" +
      "NewVerFixd=" + (($target.items_fixed // "") | @sh) + "\n" +
      "NewDwnlUrl=" + (($target.releases[]? | select(.build == ("linux-" + $ArchFamily)) | .url // "") | @sh)
    else
      ""
    end
  ' <<< "$PlexTvJson" 2>/dev/null)"

  NewVersion=$(strip_build_version "$NewVerFull")
  NewPackage="${NewDwnlUrl##*/}"
  # CALCULATE NEW PACKAGE AGE FROM RELEASE DATE
  if [[ $NewVerDate =~ ^[0-9]{1,11}$ ]] && [ "$NewVerDate" -gt 0 ]; then
    NewVerDate=$((10#$NewVerDate))
    PackageAge=$(((TodaysDate-NewVerDate)/86400))
  else
    PackageAge="-1"
  fi
else
  printf ' %s\n' "* UNABLE TO CHECK FOR LATEST VERSION OF PLEX MEDIA SERVER.."
  printf "\n"
  ExitStatus=1
fi

# PRINT PLEX STATUS/DEBUG INFO
printf '%16s %s\n'         "Synology:" "$SynoHModel ($ArchFamily), DSM $DSMVersion"
printf '%16s %s\n'         "Plex Dir:" "$(fold -w 72 -s     < <(printf '%s' "$PlexFolder") | sed '2,$s/^/                 /')"
printf '%16s %s\n'      "Running Ver:" "$RunVersion"
if [ "$NewVersion" != "" ]; then
  printf '%16s %s\n'     "Online Ver:" "$NewVersion ($ChannlName Channel for $DSMplexNID)"
  printf '%16s %s\n'       "Released:" "$(date --rfc-3339 seconds --date @"$NewVerDate" 2>/dev/null || echo "$NewVerDate") ($PackageAge+ days old)"
else
  printf '%16s %s\n'     "Online Ver:" "Nonexistent ($ChannlName Channel for $DSMplexNID)"
  ExitStatus=1
fi

# COMPARE PLEX VERSIONS
if [ -z "$RunVersion" ]; then
  printf '%17s%s\n' '' "* Plex Media Server is not installed or version could not be determined."
  ExitStatus=1
elif [ -z "$NewVersion" ]; then
  printf '%17s%s\n' '' "* Online version could not be determined, skipping version comparison."
elif /usr/bin/dpkg --compare-versions "$NewVersion" gt "$RunVersion"; then
  printf '%17s%s\n' '' "* Newer version found!"
  printf "\n"
  printf '%16s %s\n'    "New Package:" "$NewPackage"
  printf '%16s %s\n'    "Package Age:" "$PackageAge+ days old ($MinimumAge+ required for install)"
  printf "\n"

  # DOWNLOAD AND INSTALL THE PLEX UPDATE
  if [ "$PackageAge" -ge "$MinimumAge" ] || [ "$SkipAgeCheck" = "true" ]; then
    printf "%s\n" "INSTALLING NEW PACKAGE:"
    printf "%s\n" "----------------------------------------"
    printf "%s\n" "Downloading PlexMediaServer package:"
    PackagePath="$SrceFolder/Archive/Packages/$NewPackage"
    InstallOK=false
    AlreadyDownloaded=false
    if [ -f "$PackagePath" ] && tar -tf "$PackagePath" >/dev/null 2>&1; then
      printf "%s\n" "* Package already exists and is valid in local Archive"
      AlreadyDownloaded=true
    fi

    if [ "$AlreadyDownloaded" = "true" ] || /bin/wget -nv -c -P "$SrceFolder/Archive/Packages/" "$NewDwnlUrl" 2>&1; then
      if tar -tf "$PackagePath" >/dev/null 2>&1; then
        InstallOK=true
        printf "\n%s\n"   "Stopping PlexMediaServer service (JSON):"
        /usr/syno/bin/synopkg stop "PlexMediaServer" || exit 1
        printf "\n%s\n" "Installing PlexMediaServer update (JSON):"
        /usr/syno/bin/synopkg install "$PackagePath" | \
          jq -c '.results[] |= (
            if (.scripts // empty) | type == "array" then
              .scripts |= map(
                if .message then
                  .message |= (
                    gsub("<[^>]*>"; "")     # Strip HTML
                    | split("\n")[0]        # Keep only the first real line
                  )
                else . end
              )
            else .
            end
          )' || InstallOK=false
        printf "\n%s\n" "Starting PlexMediaServer service (JSON):"
        /usr/syno/bin/synopkg start "PlexMediaServer" || InstallOK=false
      else
        printf '\n %s\n' "* Downloaded package archive is corrupt or incomplete, skipping install.."
      fi
    else
      printf '\n %s\n' "* Package download failed, skipping install.."
    fi
    printf "%s\n" "----------------------------------------"
    printf "\n"
    NowVersion=$(/usr/syno/bin/synopkg version "PlexMediaServer" 2>/dev/null || echo "")
    NowVersion=$(strip_build_version "$NowVersion")
    printf '%16s %s\n'  "Update from:" "$RunVersion"
    printf '%16s %s'             "to:" "$NewVersion"

    # REPORT PLEX UPDATE STATUS
    if [ "$InstallOK" = true ] && [ -n "$NowVersion" ] && /usr/bin/dpkg --compare-versions "$NowVersion" eq "$NewVersion"; then
      printf ' %s\n' "succeeded!"
      printf "\n"
      # UPDATE LOCAL VERSION CHANGELOG ONLY ON SUCCESSFUL INSTALL
      if [ -n "$NewVerDate" ] && [ "$NewVerDate" -gt 0 ] 2>/dev/null; then
        FormattedRelDate=$(date --rfc-3339 seconds --date @"$NewVerDate" 2>/dev/null || echo "Unknown Date")
      else
        FormattedRelDate="Unknown Date"
      fi
      if ! grep -q "Version $NewVersion ($FormattedRelDate)" "$SrceFolder/Archive/Packages/changelog.txt" 2>/dev/null; then
        {
          printf "%s\n" "Version $NewVersion ($FormattedRelDate)"
          printf "%s\n" "$ChannlName Channel"
          printf "%s\n" ""
          printf "%s\n" "New Features:"
          printf "%s\n" "$NewVerAddd" | awk '{ print "* " $0 }'
          printf "%s\n" ""
          printf "%s\n" "Fixed Features:"
          printf "%s\n" "$NewVerFixd" | awk '{ print "* " $0 }'
          printf "%s\n" ""
          printf "%s\n" "----------------------------------------"
          printf "%s\n" ""
        } >> "$SrceFolder/Archive/Packages/changelog.new"
        if [ -f "$SrceFolder/Archive/Packages/changelog.new" ]; then
          if [ -f "$SrceFolder/Archive/Packages/changelog.txt" ]; then
            mv    "$SrceFolder/Archive/Packages/changelog.txt" "$SrceFolder/Archive/Packages/changelog.tmp"
            cat   "$SrceFolder/Archive/Packages/changelog.new" "$SrceFolder/Archive/Packages/changelog.tmp" > "$SrceFolder/Archive/Packages/changelog.txt"
          else
            mv    "$SrceFolder/Archive/Packages/changelog.new" "$SrceFolder/Archive/Packages/changelog.txt"
          fi
        fi
      fi
      rm -f "$SrceFolder/Archive/Packages/changelog.new" "$SrceFolder/Archive/Packages/changelog.tmp" 2>/dev/null

      if [ -n "$NewVerAddd" ]; then
        # SHOW NEW PLEX FEATURES
        printf "%s\n" "NEW FEATURES:"
        printf "%s\n" "----------------------------------------"
        printf "%s\n" "$NewVerAddd" | awk '{ print "* " $0 }'
        printf "%s\n" "----------------------------------------"
        printf "\n"
      fi
      if [ -n "$NewVerFixd" ]; then
        # SHOW FIXED PLEX FEATURES
        printf "%s\n" "FIXED FEATURES:"
        printf "%s\n" "----------------------------------------"
        printf "%s\n" "$NewVerFixd" | awk '{ print "* " $0 }'
        printf "%s\n" "----------------------------------------"
        printf "\n"
      fi
      printf "\n"
      /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update task completed successfully"}'
      ExitStatus=1
    else
      printf ' %s\n' "failed!"
      /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update task failed. Installation not newer version."}'
      ExitStatus=1
    fi
  else
    printf ' %s\n' "Plex update is too new ($PackageAge days), requires $MinimumAge+ days - skipping.."
  fi
else
  printf '%17s%s\n' '' "* No new version found."
fi

printf "\n"

# EXIT NORMALLY BUT POSSIBLY WITH FORCED EXIT STATUS FOR SCRIPT NOTIFICATIONS
if [ -n "$ExitStatus" ]; then
  exit "$ExitStatus"
fi
