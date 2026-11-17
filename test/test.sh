#!/bin/bash
# Tests for disable_adobe_services.sh, run against a fake machine.
#
#   bash test/test.sh [test-name-filter]
#   SCRIPT=/some/other/copy.sh bash test/test.sh
#
# Nothing here touches the real launchd, pluginkit, sudo or any real process:
# every one of those is a stub that reads and writes files under $SB/state.
# Fake pids are above macOS's pid ceiling, so even a stray real `kill` on one
# could not hit anything.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../disable_adobe_services.sh}"
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"
FILTER="${1:-}"
SB="$(mktemp -d "${TMPDIR:-/tmp}/adobe_disabler_test.XXXXXX")/sandbox"
trap 'rm -rf "$(dirname "$SB")"' EXIT
REAL_UID="$(id -u)"
PASS=0; FAILS=0; FAILED_NAMES=""

# --- the fake machine ---------------------------------------------------------

mkplist() {   # path label
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$2</string>
<key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
</dict></plist>
EOF
}

proc() {      # pid ppid uid path
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$SB/state/procs"
}

write_stubs() {
  mkdir -p "$SB/bin"

  cat > "$SB/bin/launchctl" <<'EOF'
#!/bin/bash
S="$STATE"
dom() { case "$1" in system*) echo system ;; *) echo gui ;; esac; }
log() { printf '%slaunchctl %s\n' "${VIA_SUDO:+sudo }" "$*" >> "$S/calls.log"; }
need_root() {
  case "$1" in system*)
    [ -n "${VIA_SUDO:-}" ] || { echo "Not privileged to change the system domain" >&2; exit 1; } ;;
  esac
}
label_of() { /usr/libexec/PlistBuddy -c 'Print :Label' "$1" 2>/dev/null; }
set_state() {   # domain-file label state
  grep -v "^$2 " "$S/disabled.$1" > "$S/disabled.$1.tmp" 2>/dev/null
  printf '%s %s\n' "$2" "$3" >> "$S/disabled.$1.tmp"
  mv "$S/disabled.$1.tmp" "$S/disabled.$1"
}
if [ -f "$S/no_gui" ]; then
  case "${2:-}" in gui/*) echo "Could not find domain for user gui: ${2#gui/}" >&2; exit 113 ;; esac
fi
cmd="$1"; shift
case "$cmd" in
  print-disabled)
    d="$(dom "$1")"
    printf '\tdisabled services = {\n'
    while read -r l st; do printf '\t\t"%s" => %s\n' "$l" "$st"; done < "$S/disabled.$d"
    printf '\t}\n\tlogin item associations = {\n\t}\n'
    ;;
  print)
    d="$(dom "$1")"
    case "$1" in
      gui/*/*|user/*/*|system/*)
        grep -qxF "${1##*/}" "$S/loaded.$d" || { echo "Could not find service" >&2; exit 113; }
        echo "$1 = { state = running }"
        ;;
      *)
        printf '%s = {\n\ttype = whatever\n\tservices = {\n' "$1"
        n=100
        while read -r l; do n=$((n + 1)); printf '\t\t%8s      - \t%s\n' "$n" "$l"; done < "$S/loaded.$d"
        printf '\t}\n\n\tunmanaged processes = {\n\t}\n\tendpoints = {\n'
        printf '\t\t   0x1a2b3    M   D   com.adobe.CCLibrary.service\n'
        printf '\t}\n\tdisabled services = {\n'
        while read -r l st; do printf '\t\t"%s" => %s\n' "$l" "$st"; done < "$S/disabled.$d"
        printf '\t}\n}\n'
        ;;
    esac
    ;;
  bootout)
    log bootout "$@"; need_root "$1"; d="$(dom "$1")"
    if [ $# -ge 2 ]; then label="$(label_of "$2")"; else label="${1##*/}"; fi
    grep -qxF "$label" "$S/sticky" 2>/dev/null && { echo "Boot-out failed: 5: Input/output error" >&2; exit 5; }
    grep -qxF "$label" "$S/loaded.$d" || { echo "Boot-out failed: 3: No such process" >&2; exit 3; }
    grep -vxF "$label" "$S/loaded.$d" > "$S/loaded.$d.tmp"; mv "$S/loaded.$d.tmp" "$S/loaded.$d"
    ;;
  bootstrap)
    log bootstrap "$@"; need_root "$1"; d="$(dom "$1")"; label="$(label_of "$2")"
    grep -qxF "$label disabled" "$S/disabled.$d" && { echo "Bootstrap failed: 119: Service is disabled" >&2; exit 119; }
    grep -qxF "$label" "$S/loaded.$d" && { echo "Bootstrap failed: 37: Operation already in progress" >&2; exit 37; }
    echo "$label" >> "$S/loaded.$d"
    ;;
  disable|enable)
    log "$cmd" "$@"; need_root "$1"; d="$(dom "$1")"; label="${1##*/}"
    if grep -qxF "$label" "$S/fail_disable" 2>/dev/null; then
      echo "Could not $cmd service: 5: Input/output error" >&2; exit 5
    fi
    set_state "$d" "$label" "${cmd}d"
    ;;
  *) echo "launchctl stub: unexpected: $cmd $*" >&2; exit 64 ;;
esac
EOF

  cat > "$SB/bin/pluginkit" <<'EOF'
#!/bin/bash
S="$STATE"
case "$1" in
  -m)
    while read -r st id; do
      [ "$st" = "=" ] && st=" "
      printf '%s    %s(1.0)\n' "$st" "$id"
    done < "$S/appex"
    ;;
  -e)
    echo "pluginkit $*" >> "$S/calls.log"
    case "$2" in ignore) new="-" ;; use) new="+" ;; *) exit 64 ;; esac
    sed "s/^. $4\$/$new $4/" "$S/appex" > "$S/appex.tmp"; mv "$S/appex.tmp" "$S/appex"
    ;;
  *) echo "pluginkit stub: unexpected: $*" >&2; exit 64 ;;
esac
EOF

  cat > "$SB/bin/ps" <<'EOF'
#!/bin/bash
S="$STATE"
case "$*" in
  "-axo pid=,ppid=,uid=,comm=") awk -F'\t' '{ printf "%7d %7d %5d %s\n", $1, $2, $3, $4 }' "$S/procs" ;;
  "-axo pid=,comm=")            awk -F'\t' '{ printf "%7d %s\n", $1, $4 }' "$S/procs" ;;
  "-p "*)
    line="$(awk -F'\t' -v p="$2" '$1 == p' "$S/procs")"
    [ -n "$line" ] || exit 1
    case "${3:-}${4:-}" in
      "")        printf '  PID TTY TIME CMD\n%s\n' "$2" ;;
      "-ocomm=") printf '%s\n' "$line" | cut -f4 ;;
      *) echo "ps stub: unexpected: $*" >&2; exit 64 ;;
    esac
    ;;
  *) echo "ps stub: unexpected: $*" >&2; exit 64 ;;
esac
EOF

  # Stands in for the shell's own `kill` (see run.bash) and for `sudo kill`.
  cat > "$SB/bin/fakekill" <<'EOF'
#!/bin/bash
S="$STATE"; sig=TERM
case "${1:-}" in
  -0) sig=0; shift ;;
  -9|-KILL) sig=KILL; shift ;;
  -15|-TERM) shift ;;
esac
rc=0
for pid in "$@"; do
  line="$(awk -F'\t' -v p="$pid" '$1 == p' "$S/procs")"
  [ -n "$line" ] || { rc=1; continue; }                          # no such process
  uid="$(printf '%s\n' "$line" | cut -f3)"
  if [ "$uid" != "$MYUID" ] && [ -z "${VIA_SUDO:-}" ]; then rc=1; continue; fi   # not ours
  [ "$sig" = 0 ] && continue
  printf '%skill -%s %s\n' "${VIA_SUDO:+sudo }" "$sig" "$(printf '%s\n' "$line" | cut -f4)" >> "$S/calls.log"
  if [ "$sig" = TERM ] && grep -qxF "$pid" "$S/ignores_term" 2>/dev/null; then continue; fi
  awk -F'\t' -v p="$pid" '$1 != p' "$S/procs" > "$S/procs.tmp"; mv "$S/procs.tmp" "$S/procs"
  # respawn file: "dying-pid<TAB>new proc line". The new one appears once.
  if [ -f "$S/respawn" ]; then
    awk -F'\t' -v p="$pid" '$1 == p { sub(/^[^\t]*\t/, ""); print }' "$S/respawn" >> "$S/procs"
    awk -F'\t' -v p="$pid" '$1 != p' "$S/respawn" > "$S/respawn.tmp"; mv "$S/respawn.tmp" "$S/respawn"
  fi
done
exit $rc
EOF

  cat > "$SB/bin/sudo" <<'EOF'
#!/bin/bash
S="$STATE"
if [ "${1:-}" = -n ]; then
  shift
  [ -f "$S/sudo_cached" ] || { echo "sudo: a password is required" >&2; exit 1; }
fi
if [ "${1:-}" = -v ]; then
  [ -f "$S/sudo_grant" ] || exit 1
  touch "$S/sudo_cached"; exit 0
fi
[ -f "$S/sudo_cached" ] || { echo "sudo: a password is required" >&2; exit 1; }
if [ "$1" = kill ]; then shift; VIA_SUDO=1 exec "$BIN/fakekill" "$@"; fi
VIA_SUDO=1 exec "$@"
EOF

  cat > "$SB/bin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -u ] && [ -f "$STATE/as_root" ]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"
EOF

  printf '#!/bin/bash\nexit 0\n' > "$SB/bin/sleep"
  chmod +x "$SB/bin"/*
}

# A stock Creative Cloud install, everything on and running.
setup() {
  rm -rf "$SB"
  mkdir -p "$SB/state" "$SB/home/Library/LaunchAgents" "$SB/dl"
  write_stubs
  local la="$SB/root/Library/LaunchAgents" ld="$SB/root/Library/LaunchDaemons"
  mkplist "$la/com.adobe.AdobeCreativeCloud.plist" com.adobe.AdobeCreativeCloud
  mkplist "$la/com.adobe.ccxprocess.plist" com.adobe.ccxprocess
  mkplist "$SB/home/Library/LaunchAgents/com.adobe.ccxprocess.plist" com.adobe.ccxprocess
  mkplist "$la/com.apple.notadobe.plist" com.apple.notadobe
  mkplist "$ld/com.adobe.acc.installer.v2.plist" com.adobe.acc.installer.v2
  mkplist "$ld/com.apple.somedaemon.plist" com.apple.somedaemon
  mkplist "$SB/root/Library/Application Support/Adobe/Creative Cloud Libraries/CCLibrary.app/Contents/Library/LaunchAgents/com.adobe.CCLibrary.plist" com.adobe.CCLibrary

  printf '%s\n' com.apple.Finder com.adobe.AdobeCreativeCloud com.adobe.ccxprocess \
    com.adobe.acc.LoginHelper application.com.adobe.acc.AdobeCreativeCloud.123.456 \
    com.apple.notadobe > "$SB/state/loaded.gui"
  printf '%s\n' com.apple.logd com.adobe.acc.installer.v2 > "$SB/state/loaded.system"
  printf 'com.apple.offthing disabled\n' > "$SB/state/disabled.gui"
  printf 'com.apple.sysoff disabled\n' > "$SB/state/disabled.system"
  printf '%s\n' '= com.adobe.accmac.ACCFinderSync' '+ com.adobe.acc.anc.ContextMenu' \
    '= com.apple.share.Mail' > "$SB/state/appex"

  : > "$SB/state/procs"; : > "$SB/state/calls.log"
  proc 1 0 0 /sbin/launchd
  proc 4000010 1 "$REAL_UID" "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app/Contents/MacOS/Creative Cloud"
  proc 4000011 4000010 "$REAL_UID" "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud Helper.app/Contents/MacOS/Creative Cloud Helper"
  proc 4000012 1 "$REAL_UID" "/Applications/Utilities/Adobe Sync/CoreSync/Core Sync.app/Contents/MacOS/Core Sync"
  proc 4000013 1 "$REAL_UID" "/Library/Application Support/Adobe/Adobe Desktop Common/ADS/Adobe Desktop Service.app/Contents/MacOS/Adobe Desktop Service"
  proc 4000020 1 "$REAL_UID" "/Applications/Safari.app/Contents/MacOS/Safari"

  # The script with its final `main` call removed, so the fake machine can be
  # pointed at before it starts.
  sed '$d' "$SCRIPT" > "$SB/lib.bash"
  cat > "$SB/run.bash" <<EOF
#!/bin/bash
kill() { "$SB/bin/fakekill" "\$@"; }
source "$SB/lib.bash"
AGENT_DIRS=("$SB/root/Library/LaunchAgents" "$SB/home/Library/LaunchAgents")
DAEMON_DIRS=("$SB/root/Library/LaunchDaemons")
BUNDLE_ROOTS=("$SB/root/Library/Application Support/Adobe")
main
EOF
}

sudo_ok() { touch "$SB/state/sudo_cached"; }

# Run the script on the fake machine with $1 piped in as the menu choice.
# Output lands in $SB/out, the exit status in RC. (Not `echo 1 | run`: that
# would run this in a subshell and lose RC.)
run() {
  local input="$1"; shift
  printf "%s\n" "$input" | env HOME="$SB/home" PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" STATE="$SB/state" \
      BIN="$SB/bin" MYUID="$REAL_UID" "$@" /bin/bash "$SB/run.bash" > "$SB/out" 2>&1
  RC=${PIPESTATUS[1]}
}

# Same, on a terminal: $1 is the keystrokes, the rest replaces the command.
run_pty() {
  local keys="$1"; shift
  [ $# -gt 0 ] || set -- /bin/bash "$SB/run.bash"
  printf '%b' "$keys" | env HOME="$SB/home" PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      STATE="$SB/state" BIN="$SB/bin" MYUID="$REAL_UID" \
      perl -e 'alarm 25; exec @ARGV' script -q /dev/null "$@" > "$SB/out" 2>&1
  RC=$?
}

# --- assertions ---------------------------------------------------------------

T=""; T_OK=1
flunk() { T_OK=0; printf '    %s\n' "$*"; }
is_off() {    # domain label
  grep -qxF "$2 disabled" "$SB/state/disabled.$1" || flunk "$2 should be marked disabled in $1"
  ! grep -qxF "$2" "$SB/state/loaded.$1" || flunk "$2 should not be loaded in $1"
}
is_enabled()  { ! grep -qxF "$2 disabled" "$SB/state/disabled.$1" || flunk "$2 should not be disabled in $1"; }
is_loaded()   { grep -qxF "$2" "$SB/state/loaded.$1" || flunk "$2 should be loaded in $1"; }
untouched()   { ! grep -qF "$1" "$SB/state/calls.log" || flunk "nothing should have touched: $1"; }
running()     { grep -qF "$1" "$SB/state/procs" || flunk "should still be running: ${1##*/}"; }
stopped()     { ! grep -qF "$1" "$SB/state/procs" || flunk "should have been stopped: ${1##*/}"; }
says()        { grep -qF -- "$1" "$SB/out" || flunk "output should say: $1"; }
never_says()  { ! grep -qF -- "$1" "$SB/out" || flunk "output should not say: $1"; }
no_changes()  { [ ! -s "$SB/state/calls.log" ] || flunk "nothing should have changed, but: $(tr '\n' ';' < "$SB/state/calls.log")"; }
rc_is()       { [ "$RC" -eq "$1" ] || flunk "exit status should be $1, was $RC"; }
rc_fails()    { [ "$RC" -ne 0 ] || flunk "exit status should be non-zero"; }

# --- launchd coverage ---------------------------------------------------------

test_disable_turns_off_agents_and_daemons_from_the_launchd_folders() {
  sudo_ok; run 1
  is_off gui com.adobe.AdobeCreativeCloud
  is_off gui com.adobe.ccxprocess
  is_off system com.adobe.acc.installer.v2
  rc_is 0
}

test_disable_turns_off_an_agent_carried_inside_an_adobe_app_bundle() {
  sudo_ok; run 1
  is_off gui com.adobe.CCLibrary
}

test_disable_turns_off_a_loaded_adobe_job_that_has_no_plist_in_the_folders() {
  sudo_ok; run 1
  is_off gui com.adobe.acc.LoginHelper
}

test_disable_leaves_other_vendors_app_instances_and_mach_endpoints_alone() {
  sudo_ok; run 1
  untouched com.apple.
  untouched application.com.adobe
  untouched com.adobe.CCLibrary.service
  is_loaded gui com.apple.Finder
  is_loaded gui com.apple.notadobe
}

test_enable_puts_back_everything_disable_turned_off() {
  sudo_ok; run 1; run 2
  is_enabled gui com.adobe.AdobeCreativeCloud; is_loaded gui com.adobe.AdobeCreativeCloud
  is_enabled gui com.adobe.ccxprocess;         is_loaded gui com.adobe.ccxprocess
  is_enabled gui com.adobe.CCLibrary
  is_enabled gui com.adobe.acc.LoginHelper
  is_enabled system com.adobe.acc.installer.v2; is_loaded system com.adobe.acc.installer.v2
  grep -qxF -- '+ com.adobe.accmac.ACCFinderSync' "$SB/state/appex" || flunk "Finder Sync should be on again"
  rc_is 0
}

test_disable_switches_off_adobe_app_extensions_only() {
  sudo_ok; run 1
  grep -qxF -- '- com.adobe.accmac.ACCFinderSync' "$SB/state/appex" || flunk "Finder Sync should be off"
  grep -qxF -- '- com.adobe.acc.anc.ContextMenu' "$SB/state/appex" || flunk "context menu should be off"
  grep -qxF -- '= com.apple.share.Mail' "$SB/state/appex" || flunk "Apple's extension should be untouched"
}

test_sudo_declined_skips_daemons_and_still_does_the_rest() {
  run 1
  is_off gui com.adobe.AdobeCreativeCloud
  is_enabled system com.adobe.acc.installer.v2
  is_loaded system com.adobe.acc.installer.v2
  stopped "Core Sync.app"
  says "sudo declined"
}

test_a_failed_launchctl_call_is_reported_and_the_exit_status_is_non_zero() {
  sudo_ok; echo com.adobe.ccxprocess > "$SB/state/fail_disable"
  run 1
  says "Input/output error"
  rc_fails
  never_says "Done. Adobe's background services are off"
}

# --- running processes --------------------------------------------------------

test_disable_stops_the_background_helpers() {
  sudo_ok; run 1
  stopped "Creative Cloud.app"; stopped "Creative Cloud Helper.app"
  stopped "Core Sync.app";      stopped "Adobe Desktop Service.app"
  running "/Applications/Safari.app"
}

test_a_creative_app_installed_outside_applications_is_never_stopped() {
  local app="/Volumes/Work/Adobe Photoshop 2025/Adobe Photoshop 2025.app/Contents/MacOS/Adobe Photoshop 2025"
  proc 4000030 1 "$REAL_UID" "$app"
  proc 4000031 1 "$REAL_UID" "$SB/home/Applications/Adobe Illustrator 2025/Adobe Illustrator.app/Contents/MacOS/Adobe Illustrator"
  proc 4000032 1 "$REAL_UID" "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic"
  sudo_ok; run 1
  running "$app"; running "Adobe Illustrator.app"; running "Adobe Lightroom Classic.app"
  never_says "Stopping Adobe Photoshop 2025"
}

test_unrelated_programs_under_a_folder_with_adobe_in_its_name_are_never_stopped() {
  proc 4000040 1 "$REAL_UID" "/Users/adobe/.nvm/versions/node/v22.0.0/bin/node"
  proc 4000041 1 "$REAL_UID" "/Users/dan/Projects/adobe_services_disabler/node_modules/.bin/esbuild"
  proc 4000042 1 "$REAL_UID" "/Users/dan/Creative Cloud Files/tools/mytool"
  sudo_ok; run 1
  running "/Users/adobe/.nvm"; running "node_modules/.bin/esbuild"; running "tools/mytool"
}

test_a_helper_is_left_alone_while_the_app_that_started_it_is_still_running() {
  local dl="/Library/Application Support/Adobe/Common/dynamiclinkmediaserver/25.0/dynamiclinkmanager.app/Contents/MacOS/dynamiclinkmanager"
  proc 4000050 1 "$REAL_UID" "/Applications/Adobe Premiere Pro 2025/Adobe Premiere Pro 2025.app/Contents/MacOS/Adobe Premiere Pro 2025"
  proc 4000051 4000050 "$REAL_UID" "$dl"
  sudo_ok; run 1
  running "$dl"
  says "Adobe Premiere Pro 2025"
  stopped "Core Sync.app"
}

test_the_same_helper_is_stopped_once_nothing_owns_it() {
  local dl="/Library/Application Support/Adobe/Common/dynamiclinkmediaserver/25.0/dynamiclinkmanager.app/Contents/MacOS/dynamiclinkmanager"
  proc 4000051 1 "$REAL_UID" "$dl"
  sudo_ok; run 1
  stopped "$dl"
}

test_a_helper_that_comes_straight_back_is_stopped_again() {
  local broker="/Library/Application Support/Adobe/Adobe Desktop Common/IPCBox/AdobeIPCBroker.app/Contents/MacOS/AdobeIPCBroker"
  proc 4000060 1 "$REAL_UID" "$broker"
  printf '4000060\t4000061\t1\t%s\t%s\n' "$REAL_UID" "$broker" > "$SB/state/respawn"
  sudo_ok; run 1
  stopped "AdobeIPCBroker.app"
}

test_a_helper_that_ignores_sigterm_is_killed() {
  echo 4000012 > "$SB/state/ignores_term"
  sudo_ok; run 1
  stopped "Core Sync.app"
}

test_disable_refuses_to_run_while_adobe_is_installing_something() {
  proc 4000070 4000010 0 "/Library/Application Support/Adobe/Adobe Desktop Common/HDBox/Setup"
  sudo_ok; run 1
  no_changes
  running "Creative Cloud.app"; running "HDBox/Setup"
  says "install"
  rc_fails
}

test_a_helper_owned_by_root_is_stopped_through_sudo_once_sudo_is_granted() {
  proc 4000080 1 0 "/Library/PrivilegedHelperTools/com.adobe.acc.installer.v2"
  sudo_ok; run 1
  stopped "/Library/PrivilegedHelperTools/com.adobe.acc.installer.v2"
}

test_a_helper_owned_by_root_gets_a_sudo_kill_hint_when_sudo_was_declined() {
  proc 4000080 1 0 "/Library/PrivilegedHelperTools/com.adobe.acc.installer.v2"
  run 1
  running "/Library/PrivilegedHelperTools/com.adobe.acc.installer.v2"
  says "sudo kill 4000080"
}

# --- how it is started --------------------------------------------------------

test_refuses_to_run_under_sudo_instead_of_acting_on_roots_account() {
  touch "$SB/state/as_root"
  run 1 SUDO_UID="$REAL_UID" SUDO_USER=someone
  no_changes
  says "without sudo"
  rc_fails
}

test_piping_anything_but_1_or_2_changes_nothing() {
  run 3
  no_changes; rc_is 0
  says "com.adobe.AdobeCreativeCloud"
}

test_no_input_and_no_terminal_says_so_instead_of_exiting_silently() {
  # cron, CI, or output sent to a file: nobody to ask and nothing piped in.
  run ""
  says "No choice given"
  no_changes; rc_is 0
}

test_works_when_started_with_sh_dash_c() {
  # The real script text, as `sh -c "$(curl ...)"` would run it. Quits at the menu.
  ( cd "$SB/dl" && echo 3 | env PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" STATE="$SB/state" \
      BIN="$SB/bin" MYUID="$REAL_UID" /bin/sh -c "$(cat "$SCRIPT")" > "$SB/out" 2>&1 ); RC=$?
  never_says "This needs bash"
  never_says "syntax error"
  says "Current Adobe launch items:"
  rc_is 0; no_changes
}

test_curl_piped_into_bash_still_gets_the_menu_on_the_terminal() {
  # stdin is the script itself, so the menu has to come from the terminal.
  # Down, Down, Enter lands on Quit.
  run_pty '\033[B\033[B\n' /bin/bash -c "cat '$SCRIPT' | /bin/bash"
  says "Disable Adobe startup services"
  no_changes
}

test_an_arrow_key_the_menu_does_not_use_does_not_quit_it() {
  # Left, then Down, Enter: should land on Enable, not bail out at Left.
  sudo_ok; run_pty '\033[D\033[B\n'
  says "Enabling com.adobe.AdobeCreativeCloud"
}

test_a_longer_key_sequence_is_swallowed_whole() {
  # Page Up is ESC [ 5 ~, and shift-F2 ends in a Q. Neither may quit or select.
  sudo_ok; run_pty '\033[5~\033[1;2Q\033[B\n'
  says "Enabling com.adobe.AdobeCreativeCloud"
}

test_application_mode_arrow_keys_move_the_selection() {
  sudo_ok; run_pty '\033OB\n'
  says "Enabling com.adobe.AdobeCreativeCloud"
}

test_q_at_the_menu_changes_nothing() {
  run_pty 'q'
  no_changes
  says "Current Adobe launch items:"
}

test_enter_on_the_first_row_disables() {
  sudo_ok; run_pty '\n'
  is_off gui com.adobe.AdobeCreativeCloud
}

# --- the downloaded copy ------------------------------------------------------

run_copy() {   # dir
  cp "$SCRIPT" "$1/disable_adobe_services.sh"
  ( cd "$1" && echo 3 | env PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" STATE="$SB/state" \
      BIN="$SB/bin" MYUID="$REAL_UID" /bin/bash disable_adobe_services.sh > "$SB/out" 2>&1 ); RC=$?
}

test_a_downloaded_copy_deletes_itself() {
  run_copy "$SB/dl"
  [ ! -e "$SB/dl/disable_adobe_services.sh" ] || flunk "the downloaded copy should be gone"
}

test_a_copy_in_a_git_worktree_is_kept() {
  # In a worktree or submodule .git is a file, not a directory.
  mkdir -p "$SB/wt"; echo "gitdir: /somewhere/.git/worktrees/wt" > "$SB/wt/.git"
  run_copy "$SB/wt"
  [ -e "$SB/wt/disable_adobe_services.sh" ] || flunk "a checkout's copy must survive"
}

# --- what it prints -----------------------------------------------------------

test_status_lists_each_item_with_its_state() {
  run 3
  grep -Eq '^  \[agent\]  com\.adobe\.AdobeCreativeCloud +enabled$' "$SB/out" || flunk "agent line missing or changed"
  grep -Eq '^  \[daemon\] com\.adobe\.acc\.installer\.v2 +enabled$' "$SB/out" || flunk "daemon line missing or changed"
  grep -Eq '^  \[appex\]  com\.adobe\.accmac\.ACCFinderSync +enabled$' "$SB/out" || flunk "appex line missing or changed"
  grep -Eq '^  \[running\] Core Sync +pid 4000012$' "$SB/out" || flunk "running line missing or changed"
  [ "$(grep -c 'com.adobe.ccxprocess' "$SB/out")" -eq 1 ] || flunk "a label in two folders should be listed once"
}

test_after_disable_it_shows_the_result_and_says_everything_is_off() {
  sudo_ok; run 1
  grep -Eq '^  \[agent\]  com\.adobe\.AdobeCreativeCloud +disabled$' "$SB/out" || flunk "should show the agent as disabled afterwards"
  says "Done. Adobe's background services are off"
}

test_after_disable_it_admits_what_is_still_on() {
  run 1     # sudo declined, so the daemon stays
  never_says "Done. Adobe's background services are off"
  says "not everything"
}

test_a_job_launchd_will_not_unload_is_called_out_not_reported_as_off() {
  echo com.adobe.ccxprocess > "$SB/state/sticky"
  sudo_ok; run 1
  grep -Eq '^  \[agent\]  com\.adobe\.ccxprocess +disabled, but still loaded$' "$SB/out" || flunk "should flag the job as still loaded"
  never_says "Done. Adobe's background services are off"
}

test_agents_are_still_handled_when_there_is_no_gui_session() {
  # Over ssh with nobody at the screen only the user/ domain exists.
  touch "$SB/state/no_gui"
  sudo_ok; run 1
  grep -qxF "com.adobe.AdobeCreativeCloud disabled" "$SB/state/disabled.gui" || flunk "agent should be marked disabled through user/"
  rc_is 0
}

test_a_machine_with_nothing_from_adobe_is_left_alone() {
  rm -rf "$SB/root" "$SB/home/Library/LaunchAgents"/*
  printf '%s\n' com.apple.Finder > "$SB/state/loaded.gui"
  printf '%s\n' com.apple.logd > "$SB/state/loaded.system"
  printf '= com.apple.share.Mail\n' > "$SB/state/appex"
  : > "$SB/state/procs"; proc 1 0 0 /sbin/launchd
  run 1
  says "Nothing from Adobe found"
  no_changes; rc_is 0
}

test_the_documented_one_liner_shows_the_menu_and_quits_cleanly() {
  # /bin/bash -c "$(curl ...)" on a terminal. Down, Down, Enter is Quit.
  run_pty '\033[B\033[B\n' /bin/bash -c "$(cat "$SCRIPT")"
  says "Disable Adobe startup services"
  never_says "syntax error"; never_says "unbound variable"
  no_changes
}

test_no_run_ever_trips_set_u_or_a_missing_command() {
  sudo_ok; run 1; never_says "unbound variable"; never_says "command not found"; never_says "stub: unexpected"
  run 2;          never_says "unbound variable"; never_says "command not found"; never_says "stub: unexpected"
}

# --- runner -------------------------------------------------------------------

for T in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
  case "$T" in *"$FILTER"*) ;; *) continue ;; esac
  setup; T_OK=1
  "$T"
  if [ "$T_OK" -eq 1 ]; then
    PASS=$((PASS + 1)); printf 'ok    %s\n' "${T#test_}"
  else
    FAILS=$((FAILS + 1)); FAILED_NAMES="$FAILED_NAMES ${T#test_}"; printf 'FAIL  %s\n' "${T#test_}"
  fi
done
printf '\n%d passed, %d failed\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ]
