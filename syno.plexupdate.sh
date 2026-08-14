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

# REDIRECT STDOUT TO TEE IN ORDER TO DUPLICATE THE OUTPUT TO THE TERMINAL AS WELL AS A .LOG FILE
exec > >(tee "$SrceFllPth.log") 2>"$SrceFllPth.debug"

# ENABLE STRICT ERROR HANDLING AND XTRACE FOR DEBUG
set -uo pipefail
set -x

# CONCURRENT EXECUTION PROTECTION (LOCK FILE)
LOCKFILE="/tmp/syno.plexupdate.lock"
if [ -f "$LOCKFILE" ]; then
  LockPid=$(cat "$LOCKFILE" 2>/dev/null || echo "unknown")
  if [ -n "$LockPid" ] && [ "$LockPid" != "unknown" ] && kill -0 "$LockPid" 2>/dev/null; then
    printf ' %s\n\n' "* Another instance is already running (PID: $LockPid) - exiting.."
    exit 1
  else
    # Stale lock file, remove it
    rm -f "$LOCKFILE"
  fi
fi
trap 'rm -f "$LOCKFILE"' EXIT
if ! (set -o noclobber; echo $$ > "$LOCKFILE") 2>/dev/null; then
  LockPid=$(cat "$LOCKFILE" 2>/dev/null || echo "unknown")
  if [ -n "$LockPid" ] && [ "$LockPid" != "unknown" ] && kill -0 "$LockPid" 2>/dev/null; then
    printf ' %s\n\n' "* Another instance is already running (PID: $LockPid) - exiting.."
    exit 1
  fi
  echo $$ > "$LOCKFILE"
fi

# SCRIPT VERSION
readonly SpuscrpVer=4.8.2
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

# LOAD CONFIG FILE IF IT EXISTS
if [ -f "$SrceFolder/config.ini" ]; then
  source "$SrceFolder/config.ini"
fi

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
ExitStatus=""

# PRINT SCRIPT STATUS/DEBUG INFO
printf '%16s %s\n'                   "Script:" "$SrceFileNm"
printf '%16s %s\n'               "Script Dir:" "$(fold -w 72 -s     < <(printf '%s' "$SrceFolder") | sed '2,$s/^/                 /')"

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
    SpusRelAge=$(((TodaysDate-SpusRlDate)/86400))
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
    if [ "$SelfUpdate" -eq "1" ]; then
      if [ "$SpusRelAge" -ge "$MinimumAge" ] || [ "$MasterUpdt" = "true" ] || [ "$SkipAgeCheck" = "true" ]; then
        printf "\n"
        printf "%s\n" "INSTALLING NEW SCRIPT:"
        printf "%s\n" "----------------------------------------"
        if /bin/wget -nv -O "$SrceFolder/Archive/Scripts/$SrceFileNm" "$SpusDwnUrl" 2>&1; then
          # MAKE A COPY FOR UPGRADE COMPARISON BECAUSE WE ARE GOING TO MOVE NOT COPY THE NEW FILE
          cp -f -v "$SrceFolder/Archive/Scripts/$SrceFileNm"     "$SrceFolder/Archive/Scripts/$SrceFileNm.cmp" 2>&1
          # MOVE-OVERWRITE INSTEAD OF COPY-OVERWRITE TO NOT CORRUPT RUNNING IN-MEMORY VERSION OF SCRIPT
          mv -f -v "$SrceFolder/Archive/Scripts/$SrceFileNm"     "$SrceFolder/$SrceFileNm"                     2>&1
          chmod +x "$SrceFolder/$SrceFileNm"
          printf "%s\n" "----------------------------------------"
          if cmp -s   "$SrceFolder/Archive/Scripts/$SrceFileNm.cmp" "$SrceFolder/$SrceFileNm"; then
            printf '%17s%s\n' '' "* Script update succeeded!"
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
          else
            printf '%17s%s\n' '' "* Script update failed to overwrite."
            /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Syno.Plex Update\n\nSelf-Update failed."}'
            ExitStatus=1
          fi
        else
          printf '%17s%s\n' '' "* Script update failed to download."
          /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Syno.Plex Update\n\nSelf-Update failed to download."}'
          ExitStatus=1
        fi
      else
        printf ' \n%s\n' "Script update is too new ($SpusRelAge days), requires $MinimumAge+ days - skipping.."
      fi
      # DELETE TEMP COMPARISON FILE
      find "$SrceFolder/Archive/Scripts" -maxdepth 1 -type f -name "$SrceFileNm.cmp" -delete
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

if [ -d "$SrceFolder/Archive/Packages" ]; then
  find "$SrceFolder/Archive/Packages" -type f -name "PlexMediaServer*.spk" -mtime +"$OldUpdates" -delete
fi

# SCRAPE PLEX ONLINE TOKEN
PlexOToken=$(grep -oP "PlexOnlineToken=\"\K[^\"]+"     "$PlexFolder/Preferences.xml" 2>/dev/null || echo "")
# CREATE MASKED TOKEN VERSION FOR LOGGING (SECURITY)
if [ -n "$PlexOToken" ]; then
  PlexOTokenMasked="****${PlexOToken: -4}"
else
  PlexOTokenMasked=""
fi
# SCRAPE PLEX SERVER UPDATE CHANNEL
PlexChannl=$(grep -oP "ButlerUpdateChannel=\"\K[^\"]+" "$PlexFolder/Preferences.xml" 2>/dev/null || echo "")
[ -n "$UpdtChannl" ] && PlexChannl="$UpdtChannl" # Override with command line option

# ROLLBACK FUNCTIONALITY
if [ "$Rollback" = "true" ]; then
  printf "\n%s\n" "ROLLBACK TO PREVIOUS VERSION:"
  printf "%s\n" "----------------------------------------"
  # Find the previous package (second most recent)
  PkgList=()
  while IFS= read -r pkg; do
    [ -n "$pkg" ] && PkgList+=("$pkg")
  done < <(ls -t "$SrceFolder/Archive/Packages/PlexMediaServer"*.spk 2>/dev/null)
  if [ "${#PkgList[@]}" -lt 2 ]; then
    printf ' %s\n' "* No previous package found in Archive (found ${#PkgList[@]} package(s)) - cannot rollback"
    printf "%s\n" "----------------------------------------"
    /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update rollback failed. No previous package found."}'
    exit 1
  fi
  PreviousPkg="${PkgList[1]}"
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
  /usr/syno/bin/synopkg stop    "PlexMediaServer"
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
    )'
  printf "\n%s\n" "Starting PlexMediaServer service (JSON):"
  /usr/syno/bin/synopkg start   "PlexMediaServer"
  printf "%s\n" "----------------------------------------"
  NowVersion=$(/usr/syno/bin/synopkg version "PlexMediaServer" 2>/dev/null || echo "")
  NowVersion=$(strip_build_version "$NowVersion")
  printf '%16s %s\n' "Rollback from:" "$RunVersion"
  printf '%16s %s'             "to:" "$NowVersion"
  if [ -n "$NowVersion" ] && /usr/bin/dpkg --compare-versions "$RunVersion" gt "$NowVersion"; then
    printf ' %s\n' "succeeded!"
    /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update rollback completed successfully"}'
  else
    printf ' %s\n' "failed!"
    /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update rollback failed."}'
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
    if [ -z "$PlexOToken" ]; then
      printf ' %s\n' "Beta channel requires a Plex Online Token but none was found - exiting.."
      /usr/syno/bin/synonotify PKGHasUpgrade '{"%PKG_HAS_UPDATE%": "Plex Media Server\n\nSyno.Plex Update task failed. Beta channel selected but no Plex Online Token found."}'
      printf "\n"
      exit 1
    fi
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
  if [ -n "$NewVerDate" ] && [ "$NewVerDate" -gt 0 ] 2>/dev/null; then
    PackageAge=$(((TodaysDate-NewVerDate)/86400))
  else
    PackageAge="0"
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
    AlreadyDownloaded=false
    if [ -f "$PackagePath" ] && tar -tf "$PackagePath" >/dev/null 2>&1; then
      printf "%s\n" "* Package already exists and is valid in local Archive"
      AlreadyDownloaded=true
    fi

    if [ "$AlreadyDownloaded" = "true" ] || /bin/wget -nv -c -P "$SrceFolder/Archive/Packages/" "$NewDwnlUrl" 2>&1; then
      if tar -tf "$PackagePath" >/dev/null 2>&1; then
        printf "\n%s\n"   "Stopping PlexMediaServer service (JSON):"
        /usr/syno/bin/synopkg stop    "PlexMediaServer"
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
          )'
        printf "\n%s\n" "Starting PlexMediaServer service (JSON):"
        /usr/syno/bin/synopkg start   "PlexMediaServer"
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
    if /usr/bin/dpkg --compare-versions "$NowVersion" gt "$RunVersion"; then
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

# CLOSE AND NORMALIZE THE LOGGING REDIRECTIONS
exec >&- 2>&- 1>&2

# EXIT NORMALLY BUT POSSIBLY WITH FORCED EXIT STATUS FOR SCRIPT NOTIFICATIONS
if [ -n "$ExitStatus" ]; then
  exit "$ExitStatus"
fi
