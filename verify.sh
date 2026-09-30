#!/bin/bash
# End-to-end test on an unlocked Omarchy device. Restores every changed setting.
set -uo pipefail
[[ $(uname -s) == Linux ]] || { echo NOT-ON-DEVICE; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/verify-out"
mkdir -p "$OUT"
STATE_DIR="$HOME/.local/state/input-menu-verify"
MANIFEST="$STATE_DIR/restore.json"
MARKER="$STATE_DIR/in-progress"
BACKUP="$STATE_DIR/backups"
TYPED="$STATE_DIR/typed-output"
state_dir_ok() {
  [[ -d $STATE_DIR && ! -L $STATE_DIR && $(stat -c '%u:%a' "$STATE_DIR") == "$(id -u):700" ]]
}
file_hash() {
  if [[ -f $1 && ! -L $1 ]]; then sha256sum "$1" | cut -d ' ' -f1
  elif [[ ! -e $1 && ! -L $1 ]]; then echo absent
  else echo invalid; fi
}
CANDIDATE_KINDS=(templates rendered hook folder state lock)
candidate_path() {
  case $1 in
    templates) echo "$HOME/.config/omarchy/themed" ;;
    rendered) echo "$HOME/.local/state/omarchy/current/theme" ;;
    hook) echo "$HOME/.config/omarchy/hooks/theme-set.d/input-menu" ;;
    folder) echo "$HOME/.local/share/fcitx5/themes/omarchy-input-menu" ;;
    state) echo "$HOME/.local/state/input-menu/theme.json" ;;
    lock) echo "$HOME/.local/state/input-menu/lock" ;;
    *) return 1 ;;
  esac
}
candidate_files() {
  local kind=$1 path=$2 f
  local -a files=()
  case $kind in
    templates) files=("$path"/input-menu-fcitx5*.tpl) ;;
    rendered) files=("$path/input-menu-fcitx5.conf" "$path"/input-menu-fcitx5-*.svg) ;;
    *) return 1 ;;
  esac
  for f in "${files[@]}"; do [[ ! -e $f && ! -L $f ]] || printf '%s\n' "$f"; done
  return 0
}
# Hash names, kinds, modes and bytes, refusing symlinks/special or foreign files.
# Shared template/render directories are not ours; only our named files count.
candidate_hash() {
  local kind=$1 path=$2 f rel data
  local -a files=()
  case $kind in
    templates|rendered) mapfile -t files < <(candidate_files "$kind" "$path" | sort) ;;
    folder)
      if [[ ! -e $path && ! -L $path ]]; then echo absent; return 0; fi
      [[ -d $path && ! -L $path ]] || { echo invalid; return 1; }
      mapfile -t files < <(find "$path" -print | sort)
      ;;
    *)
      if [[ ! -e $path && ! -L $path ]]; then echo absent; return 0; fi
      files=("$path")
      ;;
  esac
  data=$(
    for f in "${files[@]}"; do
      [[ ! -L $f && $(stat -c %u "$f") == "$(id -u)" ]] || exit 1
      rel=''
      if [[ $kind == folder && $f != "$path" ]]; then rel=${f#"$path"/}; fi
      if [[ $kind == templates || $kind == rendered ]]; then rel=${f##*/}; fi
      [[ $rel =~ ^[A-Za-z0-9_./-]*$ ]] || exit 1
      if [[ -d $f && $kind == folder ]]; then printf 'd %s %s\n' "$(stat -c %a "$f")" "$rel"
      elif [[ -f $f ]]; then printf 'f %s %s %s\n' "$(stat -c %a "$f")" "$(file_hash "$f")" "$rel"
      else exit 1; fi
    done
  ) || { echo invalid; return 1; }
  printf '%s' "$data" | sha256sum | cut -d ' ' -f1
}
save_candidate() {
  local kind path dest f
  for kind in "${CANDIDATE_KINDS[@]}"; do
    path=$(candidate_path "$kind"); dest="$BACKUP/candidate-$kind"
    candidate_hash "$kind" "$path" >/dev/null || return 1
    case $kind in
      templates|rendered)
        mkdir -m 700 "$dest" || return 1
        while IFS= read -r f; do cp -p "$f" "$dest/" || return 1; done < <(candidate_files "$kind" "$path")
        ;;
      *) [[ ! -e $path ]] || cp -a "$path" "$dest" || return 1 ;;
    esac
  done
}
candidate_hashes() {
  local kind hash out='{}'
  for kind in "${CANDIDATE_KINDS[@]}"; do
    hash=$(candidate_hash "$kind" "$BACKUP/candidate-$kind") || return 1
    out=$(jq -c --arg k "$kind" --arg h "$hash" '. + {($k):$h}' <<<"$out") || return 1
  done
  echo "$out"
}
valid_manifest() {
  [[ -f $MANIFEST && ! -L $MANIFEST && $(stat -c %u "$MANIFEST") == "$(id -u)" &&
     -d $BACKUP && ! -L $BACKUP && $(stat -c '%u:%a' "$BACKUP") == "$(id -u):700" ]] || return 1
  jq -e '
    def exact($names): (keys | sort) == ($names | sort);
    def hex: type == "string" and test("^[0-9a-f]{64}$");
    exact(["version","unit","command","pid","group","layout","pairs","im","mode","theme","position","hidden","section","lang","lcAll","shellLang","shellLcAll","backupHashes","classicui","candidateHashes"]) and
    .version == 2 and .unit == "active" and (.command | type == "string" and length > 0) and
    (.pid | type == "number" and . > 0 and floor == .) and
    (all([.group,.layout,.im,.mode,.theme,.hidden,.section,.lang,.lcAll,.shellLang,.shellLcAll][]; type == "string")) and
    (.pairs | type == "array" and length > 0 and all(.[]; type == "array" and length == 2 and all(.[]; type == "string"))) and
    (.position | IN("top","bottom","left","right")) and
    (.section | IN("left","center","right")) and
    (.shellLang | test("^[A-Za-z0-9_.@-]*$")) and
    (.shellLcAll | test("^[A-Za-z0-9_.@-]*$")) and
    (.hidden | (fromjson? | type) | IN("array","string")) and
    (.classicui | type == "object" and exact(["Theme","DarkTheme"]) and all(.[]; type == "string" and length > 0)) and
    (.candidateHashes | type == "object" and exact(["templates","rendered","hook","folder","state","lock"]) and all(.[]; . == "absent" or hex)) and
    (.backupHashes | type == "object" and
      exact(["shell.json","zz-input-menu.conf","input-menu-enable.json","theme.name","profile","input-menu-modes.json"]) and
      (.["shell.json"] | hex))
  ' "$MANIFEST" >/dev/null 2>&1 || return 1
  local name want got
  for name in shell.json zz-input-menu.conf input-menu-enable.json theme.name profile input-menu-modes.json; do
    want=$(jq -r --arg name "$name" '.backupHashes[$name] | if . == null then "absent" else . end' "$MANIFEST")
    [[ $want == absent || $want =~ ^[0-9a-f]{64}$ ]] || return 1
    got=$(file_hash "$BACKUP/$name")
    [[ $got == "$want" ]] || return 1
    [[ $want == absent || $(stat -c %u "$BACKUP/$name") == "$(id -u)" ]] || return 1
  done
  for name in "${CANDIDATE_KINDS[@]}"; do
    want=$(jq -r --arg k "$name" '.candidateHashes[$k]' "$MANIFEST")
    got=$(candidate_hash "$name" "$BACKUP/candidate-$name") || return 1
    [[ $got == "$want" ]] || return 1
  done
}
sweep_stale() {
  local path
  for path in "$STATE_DIR"/scratch.* "$STATE_DIR"/restore.json.tmp.*; do
    [[ -e $path || -L $path ]] || continue
    [[ ! -L $path && $(stat -c %u "$path") == "$(id -u)" ]] || { echo "REFUSE: unsafe stale file $path"; return 1; }
    if [[ $path == "$STATE_DIR"/scratch.* ]]; then
      [[ -d $path && $(stat -c %a "$path") == 700 ]] || return 1
      rm -r -- "$path" || return 1
    else
      [[ -f $path ]] || return 1
      rm -f -- "$path" || return 1
    fi
  done
}
manual_recovery() {
  echo "BROKEN: recovery marker has no valid bundle; do not remove it or rerun verification"
  echo "MANUAL: see $HERE/README.md (broken manifest or backup). Inspect $STATE_DIR and verify trusted backups before restoring."
  echo "If trusted: cp -p '$BACKUP/shell.json' '$HOME/.config/omarchy/shell.json'"
  echo "If originally present and trusted: cp -p '$BACKUP/zz-input-menu.conf' '$HOME/.config/systemd/user/omarchy-fcitx5.service.d/zz-input-menu.conf'"
  echo 'Inspect classicui and candidateHashes plus the candidate-* snapshots; README lists their fixed restore destinations.'
  echo 'Reload the unit, restart the shell, inspect IM/locale/theme/tray; only then clear the marker manually.'
}
if [[ ${1:-} == --status && ! -e $STATE_DIR && ! -L $STATE_DIR ]]; then echo 'CLEAN: no interrupted verification'; exit 0; fi
if [[ ! -e $STATE_DIR && ! -L $STATE_DIR ]]; then
  mkdir -p "$(dirname "$STATE_DIR")"
  mkdir -m 700 "$STATE_DIR"
fi
state_dir_ok || { echo "REFUSE: $STATE_DIR must be an owned non-symlink 0700 directory"; exit 1; }
exec {lock_fd}>"$STATE_DIR/.lock"
if ! flock -n "$lock_fd"; then
  if [[ ${1:-} == --status ]]; then echo 'RUNNING: verification or recovery holds the lock'; exit 0; fi
  echo 'REFUSE: another verification or recovery is running'; exit 1
fi
if [[ ${1:-} == --status ]]; then
  if [[ -e $MARKER ]]; then
    valid_manifest || { manual_recovery; exit 1; }
    echo "IN PROGRESS: $MARKER; preview with $HERE/verify.sh --recover"
    jq '{unit,command,pid,group,im,mode,theme,classicui,candidateHashes,position}' "$MANIFEST"
  else echo 'CLEAN: no interrupted verification'; fi
  exit 0
fi
[[ $# -eq 0 || ( $1 == --recover && $# -le 3 ) ]] || { echo 'usage: ./verify.sh [--status|--recover [--yes] [--yes-restart-fcitx5]]' >&2; exit 2; }
apply_recovery=0
allow_restart=0
if [[ ${1:-} == --recover ]]; then
  for option in "${@:2}"; do
    case $option in
      --yes) apply_recovery=1 ;;
      --yes-restart-fcitx5) allow_restart=1 ;;
      *) echo "unknown recovery option: $option"; exit 2 ;;
    esac
  done
  (( !allow_restart || apply_recovery )) || { echo '--yes-restart-fcitx5 requires --yes'; exit 2; }
fi
if [[ ${1:-} != --recover && -e $MARKER ]]; then
  echo "REFUSE: interrupted verification; run $HERE/verify.sh --recover (or --status)"
  exit 1
fi
if [[ ! -e $MARKER ]]; then
  sweep_stale || exit 1
fi
if [[ ${1:-} == --recover ]]; then
  if [[ ! -e $MARKER ]]; then echo 'REFUSE: no interrupted verification (orphan scratch swept)'; exit 1; fi
  if ! valid_manifest; then manual_recovery; exit 1; fi
  exec > >(tee "$OUT/recover.log") 2>&1
else exec > >(tee "$OUT/verify.log") 2>&1; fi
T=io.github.ray0907.input-menu
CTL=(org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1)
DROPIN="$HOME/.config/systemd/user/omarchy-fcitx5.service.d/zz-input-menu.conf"
NOSNI="$HOME/.config/systemd/user/omarchy-fcitx5.service.d/verify-nosni.conf"
ENABLE_STATE="$HOME/.local/state/input-menu-enable.json"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
mouse_pressed=0
SCRATCH=''
skips=()
fail=0
restoring=0
restore_errors=0
recovering=0
step() { echo "== $1"; }
bad() { echo "FAIL: $1"; fail=1; (( restoring )) && restore_errors=1; }
C() { qs ipc -n -p "$OMARCHY_PATH/shell" call "$T" "$@"; }
S() { C state; }
field() { S | jq -r "$1"; }
focused() { [[ $(hyprctl activewindow -j | jq -r .title) == input-menu-test ]]; }
zero_clients() { hyprctl clients -j | jq -e 'type == "array" and length == 0' >/dev/null; }
remote() { pgrep -x fcitx5 >/dev/null && fcitx5-remote "$@"; }
screenshot() { if grim "$OUT/$1.png"; then echo "screenshot: $1.png"; else bad "screenshot $1"; fi; }
pre_marker_cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [[ -e $MARKER ]]; then
    echo "RECOVERY REQUIRED: $HERE/verify.sh --recover"
    exit "$rc"
  fi
  [[ -z ${manifest_tmp:-} ]] || rm -f -- "$manifest_tmp"
  rm -f -- "$MANIFEST" "$TYPED"
  [[ ! -d $BACKUP ]] || rm -r -- "$BACKUP"
  sweep_stale
  exit "$rc"
}

# Recovery never treats mutated state as a new baseline.
if [[ ${1:-} == --recover ]]; then
  : # The validated marker and backups are loaded below, without mutating anything.
else
# qs ipc exits 0 even when its target is missing. Do not mutate the device then.
if ! S | jq -e '.status and (.inputMethods | type == "array")' >/dev/null 2>&1; then
  bad 'Input Menu IPC did not return real state JSON'
  echo SOME FAILED
  exit 1
fi
if [[ -e $NOSNI ]]; then bad "existing $NOSNI; refusing to overwrite it"; echo SOME FAILED; exit 1; fi
if [[ $(hyprctl clients -j | jq length) -ne 0 ]]; then
  echo 'REFUSE: close all client windows before testing; restarting fcitx5 cannot preserve their input contexts'
  exit 1
fi
original_theme_status=$("$HERE/scripts/theme" status --json) || { echo 'REFUSE: cannot read candidate theme baseline'; exit 1; }
jq -e '.state == "free"' <<<"$original_theme_status" >/dev/null || { echo 'REFUSE: candidate theme baseline must be free'; exit 1; }
original_classicui=$(jq -c '{Theme:.theme,DarkTheme:.darkTheme}' <<<"$original_theme_status")
echo "candidate baseline: $original_theme_status"
if [[ -e $BACKUP || -L $BACKUP ]]; then
  [[ -d $BACKUP && ! -L $BACKUP && $(stat -c '%u:%a' "$BACKUP") == "$(id -u):700" ]] ||
    { echo 'REFUSE: unsafe existing backup directory'; exit 1; }
  rm -r -- "$BACKUP"
fi
[[ ! -e $TYPED && ! -L $TYPED ]] || { echo 'REFUSE: typed output still exists'; exit 1; }
manifest_tmp=''
trap pre_marker_cleanup EXIT
trap 'exit 130' INT TERM HUP
mkdir -m 700 "$BACKUP"
cp -p "$SHELL_JSON" "$BACKUP/shell.json"
for item in "$DROPIN" "$ENABLE_STATE" "$HOME/.local/state/omarchy/current/theme.name" \
            "$HOME/.config/fcitx5/profile" "$HOME/.local/state/input-menu-modes.json"; do
  [[ ! -f $item ]] || cp -p "$item" "$BACKUP/$(basename "$item")"
done
save_candidate || { echo 'REFUSE: unsafe candidate theme files or failed backup'; exit 1; }
original_candidate_hashes=$(candidate_hashes) || exit 1
original_hidden=$(jq -c '[.bar.layout[]?[]? | select(.id=="omarchy.tray") | .hidden // []][0] // []' "$SHELL_JSON")
original_section=$(jq -r '.bar.layout | to_entries[] | select(any(.value[]?; .id == "omarchy.tray")) | .key' "$SHELL_JSON" | head -1)
original_theme=$(<"$HOME/.local/state/omarchy/current/theme.name")
original_position=$(jq -r '.bar.position // "top"' "$SHELL_JSON")
original_lang=$(systemctl --user show-environment | sed -n 's/^LANG=//p' | tail -1)
original_lc_all=$(systemctl --user show-environment | sed -n 's/^LC_ALL=//p' | tail -1)
original_shell_pid=$(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1)
if [[ -z $original_shell_pid || ! -r /proc/$original_shell_pid/environ ]]; then echo 'REFUSE: shell environment unavailable'; exit 1; fi
original_shell_lang=$(tr '\0' '\n' <"/proc/$original_shell_pid/environ" | sed -n 's/^LANG=//p' | tail -1)
original_shell_lc_all=$(tr '\0' '\n' <"/proc/$original_shell_pid/environ" | sed -n 's/^LC_ALL=//p' | tail -1)
for locale in "$original_shell_lang" "$original_shell_lc_all"; do
  [[ $locale =~ ^[A-Za-z0-9_.@-]*$ ]] || { echo 'REFUSE: unsafe original shell locale'; exit 1; }
done
original_service=$(systemctl --user is-active omarchy-fcitx5)
original_pid=$(systemctl --user show omarchy-fcitx5 -p MainPID --value)
mapfile -t fcitx_pids < <(pgrep -x fcitx5 || true)
if [[ $original_service != active || ${#fcitx_pids[@]} -ne 1 || ${fcitx_pids[0]} != "$original_pid" || ! -r /proc/$original_pid/cmdline ]]; then
  echo 'REFUSE: fcitx5 is not exclusively managed by omarchy-fcitx5; no state changed'
  exit 1
fi
original_command=$(tr '\0' ' ' <"/proc/$original_pid/cmdline")
original_snapshot=$("$HERE/scripts/snapshot")
original_icon=$(jq -r '.icon // empty' <<<"$original_snapshot")
original_mode=$(jq -r '[.items[]? | select(.radio and .sub and .checked) | .icon][0] // empty' <<<"$original_snapshot")
# With no focused client fcitx5 sometimes leaves all radio entries unchecked,
# but its published IconName still preserves the last selected Mozc mode.
if [[ -z $original_mode && $original_icon == fcitx_mozc_* ]]; then original_mode=$original_icon; fi
original_im=$(remote -n 2>/dev/null || true)
if [[ -z $original_im ]]; then
  case $original_icon in
    input-keyboard*|fcitx-keyboard*) original_im=keyboard-us ;;
    fcitx-chewing) original_im=chewing ;;
    fcitx_mozc*) original_im=mozc ;;
  esac
fi
original_group=$(busctl --user --auto-start=no --json=short call "${CTL[@]}" CurrentInputMethodGroup 2>/dev/null | jq -r '.data[0] // empty')
original_info=$(busctl --user --auto-start=no --json=short call "${CTL[@]}" InputMethodGroupInfo s "$original_group" 2>/dev/null)
original_layout=$(jq -r '.data[0] // empty' <<<"$original_info")
mapfile -t original_pairs < <(jq -r '.data[1][] | .[0], .[1]' <<<"$original_info")
if [[ -z $original_group || -z $original_layout || ${#original_pairs[@]} -lt 2 || -z $original_im ]] ||
   ! printf '%s\n' "${original_pairs[@]}" | grep -Fxq "$original_im"; then
  bad 'could not save original fcitx5 group, input method or mode'; echo SOME FAILED; exit 1
fi
echo "original launch: unit=$original_service pid=$original_pid command=$original_command; group=$original_group im=$original_im mode=${original_mode:-none}"
: > "$TYPED"
chmod 600 "$TYPED"
original_shell_hash=$(file_hash "$BACKUP/shell.json")
backup_hashes=$(jq -n \
  --arg shell "$(file_hash "$BACKUP/shell.json")" --arg dropin "$(file_hash "$BACKUP/zz-input-menu.conf")" \
  --arg enable "$(file_hash "$BACKUP/input-menu-enable.json")" --arg theme "$(file_hash "$BACKUP/theme.name")" \
  --arg profile "$(file_hash "$BACKUP/profile")" --arg cache "$(file_hash "$BACKUP/input-menu-modes.json")" \
  '{"shell.json":$shell,"zz-input-menu.conf":$dropin,"input-menu-enable.json":$enable,
    "theme.name":$theme,"profile":$profile,"input-menu-modes.json":$cache}
   | with_entries(.value |= if . == "absent" then null else . end)')
for saved in "$BACKUP"/* "$TYPED"; do sync -f "$saved" || exit 1; done
sync -f "$BACKUP" || exit 1
manifest_tmp=$(mktemp "$STATE_DIR/restore.json.tmp.XXXXXX") || exit 1
jq -n --arg unit "$original_service" \
  --argjson version 2 --argjson pid "$original_pid" --arg command "$original_command" \
  --arg group "$original_group" --arg layout "$original_layout" \
  --argjson pairs "$(jq -c '.data[1]' <<<"$original_info")" \
  --arg im "$original_im" --arg mode "$original_mode" --arg theme "$original_theme" \
  --arg position "$original_position" --arg hidden "$original_hidden" --arg section "$original_section" \
  --arg lang "$original_lang" --arg lcAll "$original_lc_all" \
  --arg shellLang "$original_shell_lang" --arg shellLcAll "$original_shell_lc_all" \
  --argjson backupHashes "$backup_hashes" --argjson classicui "$original_classicui" --argjson candidateHashes "$original_candidate_hashes" \
  '{version:$version,unit:$unit,pid:$pid,command:$command,
    group:$group,layout:$layout,pairs:$pairs,im:$im,mode:$mode,theme:$theme,
    position:$position,hidden:$hidden,section:$section,lang:$lang,lcAll:$lcAll,
    shellLang:$shellLang,shellLcAll:$shellLcAll,backupHashes:$backupHashes,classicui:$classicui,candidateHashes:$candidateHashes}' > "$manifest_tmp" || exit 1
if [[ ${VERIFY_FAIL_BEFORE_MARKER:-} == 1 ]]; then echo 'INJECTED FAILURE before marker'; exit 42; fi
sync -f "$manifest_tmp" && mv "$manifest_tmp" "$MANIFEST" && sync -f "$STATE_DIR" || exit 1
printf 'restore with %s/verify.sh --recover\n' "$HERE" > "$MARKER"
sync -f "$MARKER" && sync -f "$STATE_DIR" || exit 1
fi
service_changed=0
group_changed=0
locale_changed=0
layout_changed=0
im_changed=1
external_clients=0

backup_target() {
  case $1 in
    shell.json) echo "$SHELL_JSON" ;;
    zz-input-menu.conf) echo "$DROPIN" ;;
    input-menu-enable.json) echo "$ENABLE_STATE" ;;
    theme.name) echo "$HOME/.local/state/omarchy/current/theme.name" ;;
    profile) echo "$HOME/.config/fcitx5/profile" ;;
    input-menu-modes.json) echo "$HOME/.local/state/input-menu-modes.json" ;;
  esac
}
restore_file() {
  local source="$BACKUP/$1" target=$2
  [[ $(file_hash "$source") != "$(file_hash "$target")" ]] || return 0
  if [[ -f $source ]]; then mkdir -p "$(dirname "$target")"; cp -p "$source" "$target"
  else rm -f "$target"; fi
}
classicui_values() {
  "$HERE/scripts/theme" status --json | jq -ce '{Theme:.theme,DarkTheme:.darkTheme}'
}
restore_candidate() {
  local kind path source current f
  current=$(classicui_values) || return 1
  if [[ $current != "$original_classicui" ]]; then
    busctl --user --auto-start=no call "${CTL[@]}" SetConfig sv fcitx://config/addon/classicui 'a{sv}' 2 \
      Theme s "$(jq -r .Theme <<<"$original_classicui")" DarkTheme s "$(jq -r .DarkTheme <<<"$original_classicui")" || return 1
  fi
  [[ $(classicui_values) == "$original_classicui" ]] || return 1
  for kind in "${CANDIDATE_KINDS[@]}"; do
    path=$(candidate_path "$kind"); source="$BACKUP/candidate-$kind"
    current=$(candidate_hash "$kind" "$path") || return 1
    [[ $current != "$(candidate_hash "$kind" "$source")" ]] || continue
    case $kind in
      templates|rendered)
        while IFS= read -r f; do rm -f -- "$f" || return 1; done < <(candidate_files "$kind" "$path")
        while IFS= read -r f; do mkdir -p "$path" && cp -p "$f" "$path/" || return 1; done < <(candidate_files "$kind" "$source")
        ;;
      *)
        [[ ! -e $path ]] || rm -r -- "$path" || return 1
        [[ ! -e $source ]] || { mkdir -p "$(dirname "$path")" && cp -a "$source" "$path"; } || return 1
        ;;
    esac
  done
  busctl --user --auto-start=no call "${CTL[@]}" ReloadAddonConfig s classicui || return 1
}
restore() {
  local rc=$? current pid
  trap - EXIT INT TERM HUP
  (( rc )) && bad "script exited $rc"
  restoring=1
  if (( mouse_pressed || recovering )); then
    hyprctl dispatch 'hl.dsp.send_key_state({ key = "mouse:272", state = "up", mods = "" })' >/dev/null || bad 'release left mouse button'
    mouse_pressed=0
  fi
  step 'restore device state'
  C close >/dev/null 2>&1 || true
  # Never wait for the terminal job: kill only our exact throwaway cat process.
  if [[ -n $TYPED ]]; then
    mapfile -t owned_pids < <(pgrep -f -x "sh -c cat >> $TYPED" || true)
    (( ${#owned_pids[@]} == 0 )) || kill "${owned_pids[@]}" 2>/dev/null || bad 'closing test window'
  fi
  if (( locale_changed )); then
    if [[ -n $original_lang ]]; then systemctl --user set-environment "LANG=$original_lang" || bad 'restore LANG'
    else systemctl --user unset-environment LANG || bad 'restore LANG'; fi
    if [[ -n $original_lc_all ]]; then systemctl --user set-environment "LC_ALL=$original_lc_all" || bad 'restore LC_ALL'
    else systemctl --user unset-environment LC_ALL || bad 'restore LC_ALL'; fi
  fi
  [[ $(<"$HOME/.local/state/omarchy/current/theme.name") == "$original_theme" ]] ||
    OMARCHY_THEME_SKIP_BACKGROUND=1 omarchy-theme-set "$original_theme" >/dev/null 2>&1 || bad 'restore theme'
  [[ $(jq -r '.bar.position // "top"' "$SHELL_JSON") == "$original_position" ]] ||
    omarchy-bar position "$original_position" >/dev/null 2>&1 || bad 'restore bar position'
  restore_file zz-input-menu.conf "$DROPIN" || bad 'restore Input Menu drop-in'
  [[ ! -e $NOSNI ]] || { rm -f "$NOSNI" || bad 'remove no-SNI override'; service_changed=1; }
  restore_file input-menu-enable.json "$ENABLE_STATE" || bad 'restore enable ownership'
  if (( service_changed )); then systemctl --user daemon-reload || bad 'reload restored unit'; fi
  if (( service_changed )); then
    for ((i=0; i<20; i++)); do zero_clients && break; sleep 0.25; done
    if ! zero_clients && (( !recovering || !allow_restart )); then
      bad 'client windows remained open; fcitx5 was not restarted'
      echo "RECOVERY REQUIRED: $HERE/verify.sh --recover"
      exit 1
    fi
    if pgrep -x fcitx5 >/dev/null; then busctl --user --auto-start=no call "${CTL[@]}" Exit >/dev/null 2>&1 || true; fi
    systemctl --user stop omarchy-fcitx5 || bad 'stop temporary fcitx5'
    systemctl --user start omarchy-fcitx5 || bad 'restore managed fcitx5'
  fi
  if [[ $(systemctl --user is-active omarchy-fcitx5) != "$original_service" ]]; then bad 'restore unit activation'; fi
  for ((i=0; i<20; i++)); do
    pid=$(systemctl --user show omarchy-fcitx5 -p MainPID --value)
    [[ -r /proc/$pid/cmdline && $(tr '\0' ' ' <"/proc/$pid/cmdline") == "$original_command" ]] && break
    sleep 0.25
  done
  [[ -r /proc/$pid/cmdline && $(tr '\0' ' ' <"/proc/$pid/cmdline") == "$original_command" ]] || bad 'restore original fcitx5 launch command'
  if (( group_changed )); then
    for ((i=0; i<20; i++)); do
      busctl --user --auto-start=no call "${CTL[@]}" State >/dev/null 2>&1 && break
      sleep 0.5
    done
    if busctl --user --auto-start=no call "${CTL[@]}" State >/dev/null 2>&1; then
      busctl --user --auto-start=no call "${CTL[@]}" SetInputMethodGroupInfo 'ssa(ss)' \
        "$original_group" "$original_layout" "$(( ${#original_pairs[@]} / 2 ))" "${original_pairs[@]}" || bad 'restore fcitx5 group'
    else bad 'restore fcitx5 group: controller unavailable'; fi
  fi
  restore_candidate || bad 'restore classicui and candidate theme artifacts'
  # The full byte copy restores both layout and the original tray JSON shape.
  cmp -s "$BACKUP/shell.json" "$SHELL_JSON" || cp -p "$BACKUP/shell.json" "$SHELL_JSON" || bad 'restore full shell config'
  current=$(jq -c '[.bar.layout[]?[]? | select(.id=="omarchy.tray") | .hidden // []][0] // []' "$SHELL_JSON")
  local hidden_restore=$original_hidden
  [[ $hidden_restore == '[]' ]] && hidden_restore=null
  [[ $current == "$original_hidden" ]] ||
    omarchy-bar set omarchy.tray hidden "$hidden_restore" --json --section "$original_section" >/dev/null 2>&1 || bad 'restore tray hidden icons'
  # omarchy-restart-shell inherits Hyprland's locale, not the manager's.
  if (( locale_changed || layout_changed )); then restart_original_shell || bad 'restore original shell locale'; fi
  # A service restart invalidates existing input contexts. Only create a fresh
  # owned context when the IM actually needs restoring.
  if (( !recovering || im_changed || service_changed )); then
    open_test_window || bad 'focus fresh throwaway window for IM restoration'
    if focused; then restore_im || bad 'restore original input method and engine mode'
    else bad 'restore original input method (no focused test window)'; fi
  fi
  if [[ -n $TYPED ]]; then
    mapfile -t owned_pids < <(pgrep -f -x "sh -c cat >> $TYPED" || true)
    (( ${#owned_pids[@]} == 0 )) || kill "${owned_pids[@]}" 2>/dev/null || bad 'close IM restoration window'
    for ((i=0; i<20; i++)); do
      [[ $(hyprctl clients -j | jq length) -eq ${external_clients:-0} ]] && break
      sleep 0.25
    done
    [[ $(hyprctl clients -j | jq length) -eq ${external_clients:-0} ]] || bad 'test window remained open'
    rm -f -- "$TYPED" || bad 'remove temporary typed output'
  fi
  restore_file theme.name "$HOME/.local/state/omarchy/current/theme.name" || bad 'restore theme state file'
  restore_file profile "$HOME/.config/fcitx5/profile" || bad 'restore fcitx5 profile bytes'
  restore_file input-menu-modes.json "$HOME/.local/state/input-menu-modes.json" || bad 'restore mode cache'
  [[ $(sha256sum "$SHELL_JSON" | cut -d ' ' -f1) == "$original_shell_hash" ]] || bad 'shell config hash after restore'
  [[ $(systemctl --user show-environment | sed -n 's/^LANG=//p' | tail -1) == "$original_lang" &&
     $(systemctl --user show-environment | sed -n 's/^LC_ALL=//p' | tail -1) == "$original_lc_all" ]] || bad 'manager locale after restore'
  pid=$(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1)
  if [[ -n $pid && -r /proc/$pid/environ ]]; then
    [[ $(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^LANG=//p' | tail -1) == "$original_shell_lang" &&
       $(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^LC_ALL=//p' | tail -1) == "$original_shell_lc_all" ]] || bad 'shell locale after restore'
  else bad 'restored shell missing'; fi
  [[ $(busctl --user --auto-start=no --json=short call "${CTL[@]}" CurrentInputMethodGroup 2>/dev/null | jq -r '.data[0] // empty') == "$original_group" ]] || bad 'group after restore'
  [[ $(jq -c '[.bar.layout[]?[]? | select(.id=="omarchy.tray") | .hidden // []][0] // []' "$SHELL_JSON") == "$original_hidden" ]] || bad 'tray hidden icons after restore'
  for name in shell.json zz-input-menu.conf input-menu-enable.json theme.name profile input-menu-modes.json; do
    [[ $(file_hash "$BACKUP/$name") == "$(file_hash "$(backup_target "$name")")" ]] || bad "restored $name hash mismatch"
  done
  [[ $(classicui_values) == "$original_classicui" ]] || bad 'classicui after restore'
  for kind in "${CANDIDATE_KINDS[@]}"; do
    [[ $(candidate_hash "$kind" "$(candidate_path "$kind")") == "$(candidate_hash "$kind" "$BACKUP/candidate-$kind")" ]] || bad "restored candidate $kind hash mismatch"
  done
  if (( restore_errors )); then echo "RECOVERY REQUIRED: $HERE/verify.sh --recover"; echo "restore backup: $BACKUP"; exit 1; fi
  rm -f -- "$MARKER" || { echo "RECOVERY REQUIRED: cannot clear $MARKER"; exit 1; }
  injected_failure committed
  local leftovers=0
  rm -r -- "$BACKUP" || leftovers=1
  rm -f -- "$MANIFEST" || leftovers=1
  sweep_stale || leftovers=1
  if (( leftovers )); then echo "RESTORED WITH LEFTOVER FILES: inspect $STATE_DIR; a safe run will sweep scratch"; exit 1; fi
  if (( fail )); then echo SOME FAILED; exit 1; fi
  if (( recovering )); then echo RECOVERED; exit 0; fi
  if (( ${#skips[@]} )); then echo "PASS WITH SKIPS: ${skips[*]}"; else echo ALL PASS; fi
  exit 0
}
injected_failure() {
  if [[ ${VERIFY_FAIL_AFTER:-} == "$1" ]]; then echo "INJECTED FAILURE after $1"; exit 42; fi
  if [[ ${VERIFY_KILL_AFTER:-} == "$1" ]]; then echo "INJECTED SIGKILL after $1"; kill -9 "$$"; fi
}
restart_original_shell() {
  local command='env' i
  [[ -n $original_shell_lang ]] || command+=' -u LANG'
  [[ -n $original_shell_lc_all ]] || command+=' -u LC_ALL'
  [[ -z $original_shell_lang ]] || command+=" LANG=$original_shell_lang"
  [[ -z $original_shell_lc_all ]] || command+=" LC_ALL=$original_shell_lc_all"
  while timeout 5 quickshell kill -p "$OMARCHY_PATH/shell" --any-display >/dev/null 2>&1; do :; done
  hyprctl dispatch "hl.dsp.exec_cmd(\"$command omarchy-launch-shell\")" >/dev/null || return 1
  for ((i=0; i<30; i++)); do
    pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" >/dev/null && return 0
    sleep 0.5
  done
  return 1
}

open_test_window() {
  local previous i
  previous=$(hyprctl activewindow -j | jq -r '.address // empty')
  setsid uwsm-app -- xdg-terminal-exec --title=input-menu-test -e sh -c "cat >> $TYPED" >/dev/null 2>&1 &
  for ((i=0; i<40; i++)); do
    if focused && [[ $(hyprctl activewindow -j | jq -r '.address // empty') != "$previous" ]]; then return 0; fi
    sleep 0.5
  done
  return 1
}
restore_im() {
  local id i
  pgrep -x fcitx5 >/dev/null || return 1
  remote -s "$original_im" >/dev/null || return 1
  for ((i=0; i<20; i++)); do
    [[ $(remote -n) == "$original_im" ]] && break
    sleep 0.25
  done
  [[ $(remote -n) == "$original_im" ]] || return 1
  if [[ -n $original_mode ]]; then
    for ((i=0; i<20; i++)); do
      id=$("$HERE/scripts/snapshot" | jq -r --arg mode "$original_mode" '[.items[]? | select(.radio and .sub and .icon == $mode) | .id][0] // empty')
      [[ -n $id ]] && break
      sleep 0.25
    done
    [[ -n $id ]] || { echo "restore-im: mode $original_mode unavailable in $("$HERE/scripts/snapshot" | jq -r .icon)"; return 1; }
    "$HERE/scripts/snapshot" click "$id" >/dev/null || return 1
    for ((i=0; i<20; i++)); do
      [[ $("$HERE/scripts/snapshot" | jq -r .icon) == "$original_mode" ]] && return 0
      sleep 0.25
    done
    echo "restore-im: window=$(hyprctl activewindow -j | jq -r .address) wanted=$original_mode got=$("$HERE/scripts/snapshot" | jq -r .icon)"
    return 1
  fi
}
close_test_window() {
  local -a owned_pids
  mapfile -t owned_pids < <(pgrep -f -x "sh -c cat >> $TYPED" || true)
  (( ${#owned_pids[@]} )) || return 1
  kill "${owned_pids[@]}" || return 1
  local i
  for ((i=0; i<20; i++)); do
    if ! pgrep -f -x "sh -c cat >> $TYPED" >/dev/null && [[ $(hyprctl clients -j | jq length) -eq 0 ]]; then return 0; fi
    sleep 0.5
  done
  return 1
}
compare_item() {
  if [[ $2 == "$3" ]]; then printf 'EQUAL    %-16s current=%q baseline=%q (skipped)\n' "$1" "$2" "$3"
  else printf 'DIVERGED %-16s current=%q baseline=%q\n' "$1" "$2" "$3"; fi
}
recover_preview() {
  local unit command group_info group_name snap icon im mode manager shell_env shell_pid hidden current_hash
  unit=$(systemctl --user is-active omarchy-fcitx5 || true)
  command=unavailable
  if [[ $unit == active ]]; then
    local pid; pid=$(systemctl --user show omarchy-fcitx5 -p MainPID --value)
    [[ ! -r /proc/$pid/cmdline ]] || command=$(tr '\0' ' ' <"/proc/$pid/cmdline")
  fi
  compare_item unit "$unit" "$original_service"
  compare_item launch "$command" "$original_command"
  current_hash=$(file_hash "$DROPIN")
  compare_item drop-in "$current_hash" "$(file_hash "$BACKUP/zz-input-menu.conf")"
  service_changed=0
  [[ $unit == "$original_service" && $command == "$original_command" &&
     $current_hash == "$(file_hash "$BACKUP/zz-input-menu.conf")" && ! -e $NOSNI ]] || service_changed=1
  group_name=$(busctl --user --auto-start=no --json=short call "${CTL[@]}" CurrentInputMethodGroup 2>/dev/null | jq -r '.data[0] // "unavailable"')
  group_info=$(busctl --user --auto-start=no --json=short call "${CTL[@]}" InputMethodGroupInfo s "$group_name" 2>/dev/null | jq -c '.data // "unavailable"')
  compare_item group "$group_name:$group_info" "$original_group:$(jq -c '[.layout,.pairs]' "$MANIFEST")"
  group_changed=0
  [[ $group_name:$group_info == "$original_group:$(jq -c '[.layout,.pairs]' "$MANIFEST")" ]] || group_changed=1
  snap=$("$HERE/scripts/snapshot")
  icon=$(jq -r '.icon // "unavailable"' <<<"$snap")
  case $icon in
    input-keyboard*|fcitx-keyboard*) im=keyboard-us ;;
    fcitx-chewing) im=chewing ;;
    fcitx_mozc*) im=mozc ;;
    *) im=unavailable ;;
  esac
  mode=$(jq -r '[.items[]? | select(.radio and .sub and .checked) | .icon][0] // ""' <<<"$snap")
  [[ -n $mode || $icon != fcitx_mozc_* ]] || mode=$icon
  compare_item IM/mode "$im/$mode" "$original_im/$original_mode"
  im_changed=0
  [[ $im == "$original_im" && $mode == "$original_mode" ]] || im_changed=1
  manager="$(systemctl --user show-environment | sed -n 's/^LANG=//p' | tail -1)/$(systemctl --user show-environment | sed -n 's/^LC_ALL=//p' | tail -1)"
  compare_item manager-locale "$manager" "$original_lang/$original_lc_all"
  shell_pid=$(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1)
  shell_env=unavailable
  if [[ -n $shell_pid && -r /proc/$shell_pid/environ ]]; then
    shell_env="$(tr '\0' '\n' <"/proc/$shell_pid/environ" | sed -n 's/^LANG=//p' | tail -1)/$(tr '\0' '\n' <"/proc/$shell_pid/environ" | sed -n 's/^LC_ALL=//p' | tail -1)"
  fi
  compare_item shell-locale "$shell_env" "$original_shell_lang/$original_shell_lc_all"
  locale_changed=0
  [[ $manager == "$original_lang/$original_lc_all" && $shell_env == "$original_shell_lang/$original_shell_lc_all" ]] || locale_changed=1
  compare_item theme "$(<"$HOME/.local/state/omarchy/current/theme.name")" "$original_theme"
  compare_item classicui "$(classicui_values)" "$original_classicui"
  for kind in "${CANDIDATE_KINDS[@]}"; do
    compare_item "candidate-$kind" "$(candidate_hash "$kind" "$(candidate_path "$kind")")" "$(candidate_hash "$kind" "$BACKUP/candidate-$kind")"
  done
  compare_item bar-position "$(jq -r '.bar.position // "top"' "$SHELL_JSON")" "$original_position"
  current_hash=$(file_hash "$SHELL_JSON")
  compare_item shell.json "$current_hash" "$original_shell_hash"
  hidden=$(jq -c '[.bar.layout[]?[]? | select(.id=="omarchy.tray") | .hidden // []][0] // []' "$SHELL_JSON")
  compare_item tray-hidden "$hidden" "$original_hidden"
  layout_changed=0
  [[ $current_hash == "$original_shell_hash" ]] || layout_changed=1
  compare_item enable-state "$(file_hash "$ENABLE_STATE")" "$(file_hash "$BACKUP/input-menu-enable.json")"
  compare_item mode-cache "$(file_hash "$HOME/.local/state/input-menu-modes.json")" "$(file_hash "$BACKUP/input-menu-modes.json")"
  compare_item profile "$(file_hash "$HOME/.config/fcitx5/profile")" "$(file_hash "$BACKUP/profile")"
  (( !service_changed )) || im_changed=1
}
if [[ ${1:-} == --recover ]]; then
  original_shell_hash=$(jq -r '.backupHashes["shell.json"]' "$MANIFEST")
  [[ ! -L $TYPED ]] || { echo 'REFUSE: typed output is a symlink'; exit 1; }
  original_service=$(jq -r .unit "$MANIFEST")
  original_pid=$(jq -r .pid "$MANIFEST")
  original_command=$(jq -r .command "$MANIFEST")
  original_group=$(jq -r .group "$MANIFEST")
  original_layout=$(jq -r .layout "$MANIFEST")
  mapfile -t original_pairs < <(jq -r '.pairs[] | .[0], .[1]' "$MANIFEST")
  original_im=$(jq -r .im "$MANIFEST")
  original_mode=$(jq -r .mode "$MANIFEST")
  original_theme=$(jq -r .theme "$MANIFEST")
  original_classicui=$(jq -c .classicui "$MANIFEST")
  original_position=$(jq -r .position "$MANIFEST")
  original_hidden=$(jq -r .hidden "$MANIFEST")
  original_section=$(jq -r .section "$MANIFEST")
  original_lang=$(jq -r .lang "$MANIFEST")
  original_lc_all=$(jq -r .lcAll "$MANIFEST")
  original_shell_lang=$(jq -r .shellLang "$MANIFEST")
  original_shell_lc_all=$(jq -r .shellLcAll "$MANIFEST")
  for locale in "$original_shell_lang" "$original_shell_lc_all"; do
    [[ $locale =~ ^[A-Za-z0-9_.@-]*$ ]] || { echo 'REFUSE: unsafe shell locale in manifest'; exit 1; }
  done
  echo "Recovery preview (current versus saved baseline; no changes yet):"
  recover_preview
  if (( !apply_recovery )); then
    echo 'PREVIEW ONLY: nothing changed. Apply with ./verify.sh --recover --yes'
    exit 0
  fi
  clients=$(hyprctl clients -j)
  jq -e 'type == "array"' <<<"$clients" >/dev/null || { echo 'REFUSE: cannot inspect client windows'; exit 1; }
  external_clients=0
  while IFS=$'\t' read -r client_pid client_title; do
    [[ -n $client_pid ]] || continue
    owned=0
    if [[ $client_title == input-menu-test ]]; then
      mapfile -t cat_pids < <(pgrep -f -x "sh -c cat >> $TYPED" || true)
      for cat_pid in "${cat_pids[@]}"; do
        ancestor=$cat_pid
        for ((j=0; j<20 && ancestor>1; j++)); do
          [[ $ancestor != "$client_pid" ]] || { owned=1; break; }
          ancestor=$(ps -o ppid= -p "$ancestor" | tr -d ' ')
          [[ $ancestor =~ ^[0-9]+$ ]] || break
        done
      done
    fi
    (( owned )) || external_clients=$((external_clients + 1))
  done < <(jq -r '.[] | "\(.pid)\t\(.title)"' <<<"$clients")
  if (( service_changed && external_clients > 0 )); then
    echo 'WARNING: restarting fcitx5 can break open applications until they are refocused or reopened.'
    if (( !allow_restart )); then
      echo 'REFUSE: non-test client windows are open; close them or pass --yes-restart-fcitx5 with --yes'
      exit 1
    fi
  fi
  recovering=1
  echo 'Applying only diverged recovery state.'
fi
SCRATCH=$(mktemp -d "$STATE_DIR/scratch.XXXXXX") || { echo 'REFUSE: cannot create private scratch directory'; exit 1; }
trap restore EXIT
trap 'bad "interrupted by signal"; exit 130' INT TERM HUP
if (( recovering )); then exit 0; fi
type_line() {
  focused && wtype "$1" || return 1
  sleep 0.4
  if [[ -n ${2:-} ]]; then focused && wtype -k "$2" || return 1; sleep 0.5; fi
  focused && wtype -k Return || return 1
  sleep 0.3
  focused && wtype -k Return || return 1
  sleep 0.4
}
menu_safe() {
  [[ $(hyprctl clients -j | jq length) -eq 0 ]] && [[ $(C menuOpen) == true ]]
}
menu_key() { menu_safe && wtype -k "$1"; }
# Hidden modes and pointer hover can change the initial highlight.
menu_select_row() {
  local target=$1 current moves direction=Down i
  [[ $target =~ ^[0-9]+$ ]] || return 1
  if [[ $(field .cursorActive) != true ]]; then menu_key Down || return 1; fi
  current=$(field .selectedIndex)
  [[ $current =~ ^[0-9]+$ ]] || return 1
  moves=$(( target - current ))
  if (( moves < 0 )); then direction=Up; moves=$(( -moves )); fi
  for ((i=0; i<moves; i++)); do menu_key "$direction" || return 1; done
  [[ $(field .selectedIndex) == "$target" ]]
}

step 'model, panel and snapshot checks'
node "$HERE/test/model-check.js" || bad model-check
(cd "$HERE" && node test/panel-check.js) || bad panel-check
bash "$HERE/test/snapshot-check.sh" || bad snapshot-check

step 'validate and lint'
omarchy plugin validate "$HERE" || bad manifest
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" "$HERE/Panel.qml" "$HERE/FcitxSource.qml" >"$OUT/qmllint.log" 2>&1 || bad qmllint
if grep -E '\[(missing-property|syntax)\]' "$OUT/qmllint.log"; then bad 'QML missing property or syntax warning'; fi

step 'enable twice; one hidden Fcitx icon'
service_changed=1
"$HERE/scripts/enable" || bad 'first enable'
enabled_pid=$(pgrep -x fcitx5 | head -1)
enabled_dropin=$(stat -c '%Y:%s' "$DROPIN")
"$HERE/scripts/enable" || bad 'second enable'
[[ $(pgrep -x fcitx5 | head -1) == "$enabled_pid" && $(stat -c '%Y:%s' "$DROPIN") == "$enabled_dropin" ]] || bad 'enable was not idempotent'
hidden_count=$(jq '[.bar.layout[]?[]? | select(.id=="omarchy.tray") | (.hidden // []) | if type == "array" then . else [.] end | map(select(.=="Fcitx")) | length] | add // 0' "$SHELL_JSON")
echo "hidden Fcitx entries: $hidden_count"
[[ $hidden_count -eq 1 ]] || bad 'Fcitx hidden count'
injected_failure enable

step 'fresh empty desk shows default input method'
[[ $(hyprctl clients -j | jq length) -eq 0 ]] || { bad 'empty desk has client windows'; exit 1; }
old_shell_pid=$(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1)
mode_cache_before=$(file_hash "$HOME/.local/state/input-menu-modes.json")
omarchy-restart-shell >/dev/null 2>&1 || { bad 'restart shell on empty desk'; exit 1; }
fresh=''
for ((i=0; i<30; i++)); do
  new_shell_pid=$(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1)
  if [[ -n $new_shell_pid && $new_shell_pid != "$old_shell_pid" ]]; then
    candidate=$(S 2>/dev/null || true)
    if jq -e '.status and (.rows | type == "array")' <<<"$candidate" >/dev/null 2>&1; then
      fresh=$candidate
      if jq -e '.badgeGlyph != "?" and (.rows | length > 0) and .pendingIm == "" and
                (.rows | length) == (.inputMethods | length) and (.modes | length) == 0' <<<"$fresh" >/dev/null; then break; fi
    fi
  fi
  sleep 0.5
done
badge=$(jq -r '.badgeGlyph // "?"' <<<"$fresh" 2>/dev/null)
rows=$(jq -r '.rows | length' <<<"$fresh" 2>/dev/null)
echo "empty-desk: shell=$old_shell_pid->$new_shell_pid badge=$badge rows=${rows:-0} methods=$(jq -r '.inputMethods | length' <<<"$fresh" 2>/dev/null) modes=$(jq -r '.modes | length' <<<"$fresh" 2>/dev/null) pending=$(jq -r '.pendingIm // ""' <<<"$fresh" 2>/dev/null) focused=$(jq -r .focused <<<"$fresh" 2>/dev/null) clients=$(hyprctl clients -j | jq length)"
[[ -n $new_shell_pid && $new_shell_pid != "$old_shell_pid" && $badge != '?' && ${rows:-0} -gt 0 &&
   $(jq -r '.pendingIm // "missing"' <<<"$fresh") == '' &&
   $(jq -r '.modes | length' <<<"$fresh") -eq 0 &&
   $rows -eq $(jq -r '.inputMethods | length' <<<"$fresh") &&
   $(file_hash "$HOME/.local/state/input-menu-modes.json") == "$mode_cache_before" &&
   $(jq -r .focused <<<"$fresh") == false && $(hyprctl clients -j | jq length) -eq 0 ]] ||
  { bad 'fresh empty desk has no badge or input-method rows'; exit 1; }

step 'empty desk drops removed Mozc after fcitx5 restart'
zero_clients || { bad 'client windows open before empty-desk group change'; exit 1; }
restart_methods=$(jq -c '[.inputMethods[].icon]' <<<"$fresh")
jq -e 'index("fcitx_mozc") != null' <<<"$restart_methods" >/dev/null || { bad 'Mozc missing before empty-desk restart'; exit 1; }
restart_shell_pid=$(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1)
restart_kept=$(jq -c '[.data[1][] | select(.[0] != "mozc")]' <<<"$original_info")
mapfile -t restart_pairs < <(jq -r '.[] | .[0], .[1]' <<<"$restart_kept")
group_changed=1
busctl --user --auto-start=no call "${CTL[@]}" SetInputMethodGroupInfo 'ssa(ss)' "$original_group" "$original_layout" \
  "$(( ${#restart_pairs[@]} / 2 ))" "${restart_pairs[@]}" || { bad 'remove Mozc for empty-desk restart'; exit 1; }
for restart_stage in removed restored; do
  if [[ $restart_stage == restored ]]; then
    busctl --user --auto-start=no call "${CTL[@]}" SetInputMethodGroupInfo 'ssa(ss)' "$original_group" "$original_layout" \
      "$(( ${#original_pairs[@]} / 2 ))" "${original_pairs[@]}" || { bad 'restore group after empty-desk restart'; exit 1; }
    restart_expected=$restart_methods
    restart_expected_pairs=$(jq -c '.data[1]' <<<"$original_info")
  else
    restart_expected=$(jq -c 'map(select(. != "fcitx_mozc"))' <<<"$restart_methods")
    restart_expected_pairs=$restart_kept
  fi
  restart_info=$(busctl --user --auto-start=no --json=short call "${CTL[@]}" InputMethodGroupInfo s "$original_group")
  [[ $(jq -r '.data[0]' <<<"$restart_info") == "$original_layout" &&
     $(jq -c '.data[1]' <<<"$restart_info") == "$restart_expected_pairs" ]] || { bad 'empty-desk group order/layout mismatch'; exit 1; }
  zero_clients || { bad 'client windows open before empty-desk restart'; exit 1; }
  systemctl --user restart omarchy-fcitx5 || { bad 'empty-desk fcitx5 restart'; exit 1; }
  restart_state='{}'
  for ((i=0; i<40; i++)); do
    restart_state=$(S 2>/dev/null || true)
    if jq -e --argjson expected "$restart_expected" '.status == "ready" and .focused == false and
      [.inputMethods[].icon] == $expected' <<<"$restart_state" >/dev/null 2>&1; then break; fi
    sleep 0.25
  done
  echo "empty-desk $restart_stage: methods=$(jq -c '[.inputMethods[].icon]' <<<"$restart_state") focused=$(jq -r .focused <<<"$restart_state")"
  jq -e --argjson expected "$restart_expected" '.status == "ready" and .focused == false and
    [.inputMethods[].icon] == $expected' <<<"$restart_state" >/dev/null || { bad "stale input methods after empty-desk $restart_stage restart"; exit 1; }
  zero_clients && [[ $(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1) == "$restart_shell_pid" ]] ||
    { bad 'empty-desk check changed clients or restarted the shell'; exit 1; }
done

step 'guided install with installed engines'
zero_clients || { bad 'client windows open before guided install'; exit 1; }
pacman -Q fcitx5-chewing fcitx5-mozc >/dev/null || { bad 'guided install requires installed chewing and mozc'; exit 1; }
guide_loaded=$(busctl --user --auto-start=no --json=short call "${CTL[@]}" AvailableInputMethods) || { bad 'read loaded engines'; exit 1; }
jq -e '[.data[0][][0]] | index("chewing") != null and index("mozc") != null' <<<"$guide_loaded" >/dev/null || { bad 'guided install engines are not already loaded'; exit 1; }
guide_group=$(busctl --user --auto-start=no --json=short call "${CTL[@]}" CurrentInputMethodGroup | jq -er '.data[0]') || { bad 'read guided install group'; exit 1; }
guide_info=$(busctl --user --auto-start=no --json=short call "${CTL[@]}" InputMethodGroupInfo s "$guide_group") || { bad 'read guided install entries'; exit 1; }
guide_layout=$(jq -r '.data[0]' <<<"$guide_info")
guide_keep=$(jq -c '[.data[1][] | select(.[0] != "chewing" and .[0] != "mozc")]' <<<"$guide_info")
guide_engines=$(jq -c '[.data[1][] | select(.[0] == "chewing" or .[0] == "mozc")]' <<<"$guide_info")
jq -e 'length == 2 and (map(.[0]) | unique | length) == 2' <<<"$guide_engines" >/dev/null || { bad 'guided install needs both original group entries'; exit 1; }
guide_expected=$(jq -cn --arg layout "$guide_layout" --argjson keep "$guide_keep" --argjson engines "$guide_engines" '[$layout, $keep + $engines]')
mapfile -t guide_pairs < <(jq -r '.[] | .[0], .[1]' <<<"$guide_keep")
guide_pid=$(systemctl --user show omarchy-fcitx5 -p MainPID --value)
mkdir "$SCRATCH/pkg-guard" || { bad 'create package guard'; exit 1; }
cat >"$SCRATCH/pkg-guard/omarchy-pkg-add" <<'GUARD'
#!/bin/bash
printf 'unexpected pkg-add: %s\n' "$*" >>"${INPUT_MENU_PKG_LOG:?}"
echo 'REFUSE: verification must not install packages' >&2
exit 1
GUARD
chmod +x "$SCRATCH/pkg-guard/omarchy-pkg-add"
: >"$SCRATCH/pkg-add.calls"
group_changed=1
busctl --user --auto-start=no call "${CTL[@]}" SetInputMethodGroupInfo 'ssa(ss)' \
  "$guide_group" "$guide_layout" "$(( ${#guide_pairs[@]} / 2 ))" "${guide_pairs[@]}" || { bad 'remove installed engines from group'; exit 1; }
injected_failure guided-install
zero_clients || { bad 'client windows appeared before add-engine'; exit 1; }
guide_output=$(INPUT_MENU_PKG_LOG="$SCRATCH/pkg-add.calls" PATH="$SCRATCH/pkg-guard:$PATH" \
  "$HERE/scripts/add-engine" --engines fcitx5-chewing,fcitx5-mozc --yes 2>&1) || { echo "$guide_output"; bad 'add installed engines'; exit 1; }
echo "$guide_output"
guide_after=$(busctl --user --auto-start=no --json=short call "${CTL[@]}" InputMethodGroupInfo s "$guide_group" | jq -c '.data')
[[ $guide_after == "$guide_expected" && $(systemctl --user show omarchy-fcitx5 -p MainPID --value) == "$guide_pid" && ! -s $SCRATCH/pkg-add.calls ]] || { bad 'guided install changed order/layouts, restarted fcitx5 or invoked pkg-add'; exit 1; }
guide_profile=$(file_hash "$HOME/.config/fcitx5/profile")
guide_output=$(INPUT_MENU_PKG_LOG="$SCRATCH/pkg-add.calls" PATH="$SCRATCH/pkg-guard:$PATH" \
  "$HERE/scripts/add-engine" --engines fcitx5-chewing,fcitx5-mozc --yes 2>&1) || { echo "$guide_output"; bad 'repeat guided install'; exit 1; }
echo "$guide_output"
[[ $guide_output == *'Already set up'* && $(busctl --user --auto-start=no --json=short call "${CTL[@]}" CurrentInputMethodGroup | jq -r '.data[0]') == "$guide_group" &&
   $(busctl --user --auto-start=no --json=short call "${CTL[@]}" InputMethodGroupInfo s "$guide_group" | jq -c '.data') == "$guide_expected" &&
   $(systemctl --user show omarchy-fcitx5 -p MainPID --value) == "$guide_pid" &&
   $(file_hash "$HOME/.config/fcitx5/profile") == "$guide_profile" && ! -s $SCRATCH/pkg-add.calls ]] || { bad 'repeat guided install was not a no-op'; exit 1; }
echo "guided install: exact entries/layouts=$guide_after pid=$guide_pid unchanged; pkg-add calls=0"
: >"$TYPED"
if open_test_window; then
  C switchTo fcitx-chewing '' >/dev/null; sleep 2
  type_line su3 || bad 'Zhuyin typing after guided install'
  close_test_window || bad 'close guided install typing window'
  typed=$(tr '\n' '|' <"$TYPED")
  echo "guided install typed: [$typed]"
  [[ $typed == '你|' ]] || bad 'guided install Zhuyin typing result'
else bad 'guided install test window never received focus'; fi
: >"$TYPED"

step 'badge follows input methods and Mozc modes'
: > "$TYPED"
if open_test_window; then
  KB=$(field '.inputMethods[] | .icon' | grep -m1 -E '^(input-keyboard|fcitx-keyboard)')
  [[ -n $KB ]] || bad 'keyboard row not present'
  for pair in "$KB:" 'fcitx-chewing:' 'fcitx_mozc:fcitx_mozc_hiragana' 'fcitx_mozc:fcitx_mozc_katakana_full' 'fcitx_mozc:fcitx_mozc_alpha_half'; do
    im=${pair%%:*}; mode=${pair#*:}
    C switchTo "$im" "$mode" >/dev/null; sleep 2
    S > "$SCRATCH/state-latest.json"
    got=$(jq -r .iconName "$SCRATCH/state-latest.json"); current=$(jq -r .currentIm "$SCRATCH/state-latest.json")
    glyph=$(jq -r .badgeGlyph "$SCRATCH/state-latest.json")
    sni_icon=$("$HERE/scripts/snapshot" | jq -r .icon)
    case $sni_icon in
      input-keyboard*|fcitx-keyboard*|fcitx_mozc_alpha_half) expected=A ;;
      fcitx-chewing) expected=ㄅ ;;
      fcitx_mozc_hiragana) expected=あ ;;
      fcitx_mozc_katakana_full) expected=ア ;;
      *) expected=UNEXPECTED ;;
    esac
    echo "$pair -> icon=$got sni=$sni_icon glyph=$glyph im=$current"
    [[ $got == "$sni_icon" && $glyph == "$expected" && $expected != UNEXPECTED ]] || bad "rendered badge disagrees with independent SNI $pair"
    [[ -n $(jq -r .badgeTitle "$SCRATCH/state-latest.json") ]] || bad "missing badge title $pair"
    [[ $current == "$im" ]] || bad "switch to $im"
    if [[ -n $mode ]]; then [[ $got == "$mode" ]] || bad "mode $mode"
    elif [[ $im == "$KB" ]]; then [[ $got == input-keyboard* || $got == fcitx-keyboard* ]] || bad 'keyboard badge'
    else [[ $got == "$im" ]] || bad "badge $im"; fi
  done

  step 'default Hiragana menu has only ABC, Zhuyin and Hiragana'
  C switchTo fcitx_mozc fcitx_mozc_hiragana >/dev/null; sleep 2
  C open >/dev/null; sleep 0.7
  default_menu=$(S)
  echo "default Hiragana rows: $(jq -c '.rows' <<<"$default_menu")"
  jq -e --arg kb "$KB" '[.rows[] | {im,mode}] == [
    {im:$kb,mode:""}, {im:"fcitx-chewing",mode:""}, {im:"fcitx_mozc",mode:"fcitx_mozc_hiragana"}] and
    .currentMode == "fcitx_mozc_hiragana" and .rows[2].checked' <<<"$default_menu" >/dev/null || bad 'default Hiragana menu exposes extra or wrong rows'
  C close >/dev/null

  step 'menu screenshot in Katakana'
  C switchTo fcitx_mozc fcitx_mozc_katakana_full >/dev/null; sleep 2
  C open >/dev/null; sleep 0.8; screenshot menu; C close >/dev/null

  step 'switch from open menu, type into input-menu-test'
  for pair in 'fcitx-chewing:;su3;' 'fcitx_mozc:fcitx_mozc_hiragana;toukyou;space' 'fcitx_mozc:fcitx_mozc_katakana_full;ka;'; do
    IFS=';' read -r target input extra <<<"$pair"
    im=${target%%:*}; mode=${target#*:}
    C open >/dev/null; sleep 0.8
    C switchTo "$im" "$mode" >/dev/null; C close >/dev/null; sleep 2
    type_line "$input" "$extra" || bad "typing after $target (focus must be input-menu-test)"
  done
  close_test_window || bad 'close typing window'
  typed=$(tr '\n' '|' <"$TYPED")
  echo "typed: [$typed]"
  [[ $typed == '你|東京|カ|' ]] || bad 'typing result'

  step 'Shift_L follows fcitx5 mode toggle'
  if open_test_window; then
    C switchTo fcitx_mozc fcitx_mozc_hiragana >/dev/null; sleep 2
    if focused; then wtype -k Shift_L || bad 'Shift_L key'; else bad 'Shift_L focus check'; fi
    sleep 1.2; a=$(field .iconName)
    if focused; then wtype -k Shift_L || bad 'second Shift_L key'; else bad 'second Shift_L focus check'; fi
    sleep 1.2; b=$(field .iconName)
    echo "shift: $a, again: $b"
    [[ $a == input-keyboard* || $a == fcitx-keyboard* ]] || bad 'Shift_L did not show ABC'
    [[ $b == fcitx_mozc_hiragana ]] || bad 'Shift_L did not restore Hiragana'
    C switchTo "$KB" '' >/dev/null; sleep 2
    close_test_window || bad 'close Shift_L window'
  else bad 'Shift_L test window not focused'; fi
else bad 'test window never received focus'; fi

step 'no focused window retains last badge'
before=$(field .iconName); sleep 1; after=$(field .iconName)
echo "no-window: $before -> $after; focused=$(field .focused)"
[[ -n $after && $before == "$after" && $(field .focused) == false ]] || bad 'badge changed without focus'

step 'keyboard navigation and Enter-on-open (zero clients only)'
if [[ $(hyprctl clients -j | jq length) -eq 0 ]]; then
  C open >/dev/null; sleep 0.7
  if menu_safe; then
    S | jq -e '.selectedIndex >= 0 and .selectedIndex < (.rows | length)' >/dev/null ||
      { bad 'Enter-on-open would activate a footer action'; exit 1; }
    menu_key Return || bad 'Enter-on-open key guard'
    sleep 0.5
    echo "enter-open: menu=$(C menuOpen) pending=$(field .pendingIm)"
    [[ $(C menuOpen) == false && -n $(field .pendingIm) ]] || bad 'Enter-on-open did not activate row'
    sleep 11
    C open >/dev/null; sleep 0.7
    if menu_safe; then
      menu_key Down || { bad 'keyboard arrow guard'; exit 1; }
      target_index=$(S | jq -r '[.rows[].im == "fcitx-chewing"] | index(true) // empty')
      menu_select_row "$target_index" || { bad 'keyboard arrow/highlight guard'; exit 1; }
      screenshot menu-keyboard
      if menu_safe; then menu_key Return || bad 'keyboard Enter guard'; fi
      sleep 0.5
      echo "arrows-enter: menu=$(C menuOpen) pending=$(field .pendingIm)"
      [[ $(C menuOpen) == false && $(field .pendingIm) == fcitx-chewing ]] || bad 'arrows/Enter did not select Zhuyin'
      sleep 11
    else skips+=(menu-keys); echo 'SKIP: menu keys (menu no longer open or another client exists)'; C close >/dev/null; fi
  else skips+=(menu-keys); echo 'SKIP: menu keys (menu not open or another client exists)'; C close >/dev/null; fi
else skips+=(menu-keys); echo 'SKIP: menu keys (other client windows exist)'; fi

step 'Hiragana selected by menu keyboard from active Katakana, then typed into a new window'
if [[ $(hyprctl clients -j | jq length) -eq 0 ]]; then
  if open_test_window; then
    C switchTo fcitx_mozc fcitx_mozc_katakana_full >/dev/null; sleep 2
    close_test_window || { bad 'close active Katakana setup window'; exit 1; }
  else bad 'active Katakana setup window not focused'; exit 1; fi
  C open >/dev/null; sleep 0.7
  if menu_safe; then
    active_menu=$(S)
    jq -e '.currentIm == "fcitx_mozc" and .currentMode == "fcitx_mozc_katakana_full" and
      any(.rows[]; .im == "fcitx_mozc" and .mode == "fcitx_mozc_katakana_full" and .checked)' <<<"$active_menu" >/dev/null ||
      { bad 'active hidden Katakana row missing or unchecked'; exit 1; }
    echo "active Katakana rows: $(jq -c '.rows' <<<"$active_menu")"
    target_index=$(jq -r '[.rows[].mode == "fcitx_mozc_hiragana"] | index(true) // empty' <<<"$active_menu")
    if [[ -z $target_index ]]; then bad 'Hiragana menu row missing'; exit 1; fi
    menu_select_row "$target_index" || { bad 'Hiragana arrow/highlight guard'; exit 1; }
    screenshot menu-keyboard-hiragana
    if menu_safe; then menu_key Return || bad 'Hiragana Enter guard'; fi
    sleep 0.5
    echo "menu-hiragana: open=$(C menuOpen) im=$(field .pendingIm) mode=$(field .pendingMode)"
    [[ $(C menuOpen) == false && $(field .pendingIm) == fcitx_mozc &&
       $(field .pendingMode) == fcitx_mozc_hiragana ]] || bad 'Hiragana menu selection'
    if open_test_window; then
      sleep 2
      type_line ka || bad 'typing after Hiragana menu selection (focus check)'
      close_test_window || bad 'close Hiragana menu test window'
      last=$(tail -n 1 "$TYPED")
      echo "menu-hiragana typed: [$last]"
      [[ $last == か ]] || bad 'Hiragana menu selection typed the wrong text'
    else bad 'Hiragana menu test window not focused'; fi
  else skips+=(menu-Hiragana); echo 'SKIP: Hiragana menu selection (menu not open or another client exists)'; C close >/dev/null; fi
else skips+=(menu-Hiragana); echo 'SKIP: Hiragana menu selection (other client windows exist)'; fi

step 'mouse selection (zero clients and menu open only)'
if [[ $(hyprctl clients -j | jq length) -eq 0 ]]; then
  C open >/dev/null; sleep 0.7
  if menu_safe; then
    # Rendered row center in keyboard-panel-local coordinates plus its layer origin.
    target_index=$(S | jq '[.rows[].im == "fcitx-chewing"] | index(true)')
    target=$(C mouseTarget "$target_index")
    layer=$(hyprctl layers -j | jq -c '[.[] | .levels[][]? | select(.namespace == "omarchy-keyboard-panel") | {x,y}][0]')
    if [[ -n $target && $layer != null ]]; then
      x=$(( $(jq -r .x <<<"$target") + $(jq -r .x <<<"$layer") ))
      y=$(( $(jq -r .y <<<"$target") + $(jq -r .y <<<"$layer") ))
      echo "mouse target: Chewing at $x,$y from row geometry and keyboard layer"
      move=$(hyprctl dispatch "hl.dsp.cursor.move({ x = $x, y = $y })" 2>&1)
      if [[ $move == ok ]] && menu_safe; then
        screenshot menu-mouse
        mouse_pressed=1 # Release even if a down event or a later assertion fails.
        down=$(hyprctl dispatch 'hl.dsp.send_key_state({ key = "mouse:272", state = "down", mods = "" })' 2>&1)
        sleep 0.1
        up=$(hyprctl dispatch 'hl.dsp.send_key_state({ key = "mouse:272", state = "up", mods = "" })' 2>&1)
        [[ $up != ok ]] || mouse_pressed=0
        sleep 0.5
        echo "mouse dispatcher: move=$move down=$down up=$up menu=$(C menuOpen) pending=$(field .pendingIm)"
        if [[ $down == ok && $up == ok && $(C menuOpen) == false && $(field .pendingIm) == fcitx-chewing ]]; then
          echo 'mouse: Chewing selected'
        else skips+=(mouse-click); echo 'SKIP: compositor accepted synthetic button events but menu did not receive a click'; fi
      else skips+=(mouse-click); echo "SKIP: cursor move or menu guard failed ($move)"; fi
    else skips+=(mouse-click); echo 'SKIP: rendered row or keyboard layer not found'; fi
  else skips+=(mouse-click); echo 'SKIP: mouse (menu not open or another client exists)'; fi
  C close >/dev/null; sleep 11
else skips+=(mouse-click); echo 'SKIP: mouse (other client windows exist)'; fi

step 'fcitx5 down, dimmed notice, recovery without shell restart'
shell_before=$(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1)
service_changed=1
zero_clients || { bad 'client windows open before fcitx5-down check'; exit 1; }
if pgrep -x fcitx5 >/dev/null; then busctl --user --auto-start=no call "${CTL[@]}" Exit >/dev/null 2>&1 || true; fi
systemctl --user stop omarchy-fcitx5 || bad 'stop fcitx5'
sleep 2
echo "down: $(field .status); icon=$(field .iconName)"
[[ $(field .status) == down && -n $(field .iconName) ]] || bad 'down state/badge'
C open >/dev/null; sleep 0.8; screenshot menu-down; C close >/dev/null
systemctl --user start omarchy-fcitx5 || bad 'start fcitx5'
sleep 3
echo "recovered: $(field .status)"
[[ $(field .status) == ready ]] || bad 'fcitx5 did not recover'
[[ $(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1) == "$shell_before" ]] || bad 'recovery required shell restart'

step 'one input method; menu-open group refresh without focus change'
if open_test_window; then
  group_changed=1
  focus_before=$(field .focusEvents)
  busctl --user --auto-start=no call "${CTL[@]}" SetInputMethodGroupInfo 'ssa(ss)' \
    "$original_group" "$original_layout" 1 "${original_pairs[0]}" "${original_pairs[1]}" || bad 'set one-IM group'
  injected_failure group
  C open >/dev/null; sleep 1.5
  echo "one-IM: $(field .singleInputMethod); methods=$(S | jq '.inputMethods | length'); rows=$(S | jq '.rows | length'); focusEvents=$(field .focusEvents)"
  [[ $(field .singleInputMethod) == true && $(S | jq '.inputMethods | length') -eq 1 && $(S | jq '.rows | length') -eq 1 && $(field .focusEvents) == "$focus_before" ]] || bad 'menu-open group refresh did not show exactly one row with unchanged focus'
  screenshot menu-single; C close >/dev/null
  busctl --user --auto-start=no call "${CTL[@]}" SetInputMethodGroupInfo 'ssa(ss)' \
    "$original_group" "$original_layout" "$(( ${#original_pairs[@]} / 2 ))" "${original_pairs[@]}" || bad 'restore group after screenshot'
  C open >/dev/null; sleep 1.5
  echo "restored-IM: methods=$(S | jq '.inputMethods | length'); rows=$(S | jq '.rows | length'); focused=$(field .focused)"
  [[ $(S | jq '.inputMethods | length') -eq $(( ${#original_pairs[@]} / 2 )) && $(S | jq '.rows | length') -gt 1 &&
     $(field .focused) == true && $(hyprctl activewindow -j | jq -r .title) == input-menu-test ]] || bad 'restored group rows did not refresh in the focused test window'
  C close >/dev/null
else bad 'single-IM test window not focused'; exit 1; fi

step 'noSni notice, then enable and recover'
close_test_window || { bad 'close owned window before noSni restart'; exit 1; }
zero_clients || { bad 'client windows open before noSni restart'; exit 1; }
"$HERE/scripts/disable" || bad 'disable for noSni'
base_exec=$(systemctl --user show omarchy-fcitx5 -p ExecStart --value)
if [[ $base_exec != *'--disable notificationitem'* ]]; then
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/fcitx5 --disable notificationitem\n' > "$NOSNI"
  systemctl --user daemon-reload || bad 'reload noSni override'
fi
if pgrep -x fcitx5 >/dev/null; then busctl --user --auto-start=no call "${CTL[@]}" Exit >/dev/null 2>&1 || true; fi
systemctl --user stop omarchy-fcitx5 || bad 'stop fcitx5 for noSni'
systemctl --user start omarchy-fcitx5 || bad 'start fcitx5 without SNI'
sleep 4
C open >/dev/null; sleep 0.8 # Opening rechecks a controller that started without a tray item.
echo "noSni: $(field .status)"
[[ $(field .status) == noSni ]] || bad 'noSni status'
screenshot menu-nosni; C close >/dev/null
injected_failure noSni
if [[ -e $NOSNI ]]; then rm -f "$NOSNI"; systemctl --user daemon-reload; fi
zero_clients || { bad 'client windows open before enable after noSni'; exit 1; }
"$HERE/scripts/enable" || bad 'enable after noSni'
sleep 2
echo "enabled: $(field .status)"
[[ $(field .status) == ready ]] || bad 'enable did not recover SNI'
open_test_window || { bad 'fresh owned context after noSni restart'; exit 1; }

step 'locales en, ja, zh-TW'
# omarchy-restart-shell spawns from Hyprland, not its caller or user manager.
# Set the manager environment as requested, and launch via Hyprland with the
# same explicit values so the actual shell process receives the locale.
locale_changed=1
for loc in en_US.UTF-8 ja_JP.UTF-8 zh_TW.UTF-8; do
  systemctl --user set-environment "LANG=$loc" "LC_ALL=$loc" || bad "manager locale $loc"
  while timeout 5 quickshell kill -p "$OMARCHY_PATH/shell" --any-display >/dev/null 2>&1; do :; done
  hyprctl dispatch "hl.dsp.exec_cmd(\"env LANG=$loc LC_ALL=$loc omarchy-launch-shell\")" >/dev/null || bad "launch locale $loc"
  sleep 5
  pid=$(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1)
  actual=$(tr '\0' '\n' <"/proc/$pid/environ" | grep '^LANG=' | head -1)
  echo "locale $loc: $actual"
  [[ $actual == "LANG=$loc" ]] || bad "shell locale $loc"
  C open >/dev/null; sleep 0.8; screenshot "menu-$loc"; C close >/dev/null
 done
if [[ -n $original_lang ]]; then systemctl --user set-environment "LANG=$original_lang"; else systemctl --user unset-environment LANG; fi
if [[ -n $original_lc_all ]]; then systemctl --user set-environment "LC_ALL=$original_lc_all"; else systemctl --user unset-environment LC_ALL; fi
omarchy-restart-shell >/dev/null 2>&1 || bad 'restart original-locale shell'

step 'light theme and restore'
OMARCHY_THEME_SKIP_BACKGROUND=1 omarchy-theme-set flexoki-light >/dev/null 2>&1 || bad 'set flexoki-light'
sleep 3
C open >/dev/null; sleep 0.8; screenshot menu-light; C close >/dev/null
OMARCHY_THEME_SKIP_BACKGROUND=1 omarchy-theme-set "$original_theme" >/dev/null 2>&1 || bad 'restore theme after screenshot'

step 'vertical bar and restore'
omarchy-bar position left >/dev/null 2>&1 || bad 'set left bar'
sleep 3
C open >/dev/null; sleep 0.8; screenshot menu-vertical; C close >/dev/null
omarchy-bar position "$original_position" >/dev/null 2>&1 || bad 'restore bar after screenshot'
sleep 3
[[ $(<"$HOME/.local/state/omarchy/current/theme.name") == "$original_theme" ]] || bad 'theme not restored'
[[ $(jq -r '.bar.position // "top"' "$SHELL_JSON") == "$original_position" ]] || bad 'bar position not restored'

palette() {
  local value
  value=$(awk -F= -v key="$1" '$1 ~ "^" key "[[:space:]]*$" { gsub(/["[:space:]]/, "", $2); print $2; exit }' "$HOME/.local/state/omarchy/current/theme/colors.toml")
  [[ $value =~ ^#[0-9A-Fa-f]{6}$ ]] || return 1
  echo "$value"
}
ini_value() {
  awk -v section="[$1]" -v key="$2=" '
    /^\[/ { active = ($0 == section) }
    active && index($0, key) == 1 { print substr($0, length(key) + 1); exit }
  ' "$(candidate_path folder)/theme.conf"
}
theme_palette_matches() {
  local section image path count=0
  path=$(candidate_path folder)
  [[ -f $path/theme.conf ]] || return 1
  for section in InputPanel Menu; do
    [[ $(ini_value "$section/Background" BorderColor) == "$accent" &&
       $(ini_value "$section/Background" Color) == "$background" &&
       $(ini_value "$section/Highlight" Color) == "$accent" &&
       $(ini_value "$section" NormalColor) == "$foreground" &&
       $(ini_value "$section" HighlightCandidateColor) == "$background" ]] || return 1
  done
  [[ $(ini_value InputPanel HighlightBackgroundColor) == "$selection" ]] || return 1
  while IFS= read -r image; do
    [[ $image =~ ^(prev|next|arrow|radio)-[0-9a-f]{8}\.svg$ && -f $path/$image ]] || return 1
    [[ ${image##*-} == "$(sha256sum "$path/$image" | cut -c1-8).svg" ]] || return 1
    if [[ $image == radio-* ]]; then grep -qF "fill=\"$foreground\"" "$path/$image" || return 1
    else grep -qF "stroke=\"$foreground\"" "$path/$image" || return 1; fi
    count=$((count + 1))
  done < <(sed -n 's/^Image=//p' "$path/theme.conf")
  [[ $count == 4 ]]
}
candidate_fingerprint() {
  local kind
  for kind in "${CANDIDATE_KINDS[@]}"; do printf '%s %s\n' "$kind" "$(candidate_hash "$kind" "$(candidate_path "$kind")")"; done
}
candidate_mtimes() {
  local f
  while IFS= read -r f; do stat -c '%y %n' "$f"; done < <(
    find "$(candidate_path folder)" -print | sort
    echo "$(candidate_path templates)"
    candidate_files templates "$(candidate_path templates)" | sort
    echo "$(candidate_path hook)"
  )
}
candidate_removed() {
  [[ -z $(candidate_files templates "$(candidate_path templates)") ]] || return 1
  local kind
  for kind in hook folder state lock; do [[ ! -e $(candidate_path "$kind") && ! -L $(candidate_path "$kind") ]] || return 1; done
}

step 'candidate theme ownership and idempotence'
close_test_window || { bad 'close prior test window before candidate theme checks'; exit 1; }
C close >/dev/null
# Earlier tray-enable checks also enable the theme. Return to the saved free values.
"$HERE/scripts/theme" disable || { bad 'reset candidate theme for ownership checks'; exit 1; }
[[ $("$HERE/scripts/theme" status) == free ]] || { bad 'candidate theme baseline is not free'; exit 1; }
"$HERE/scripts/theme" enable --auto || { bad 'auto-enable candidate theme'; exit 1; }
[[ $("$HERE/scripts/theme" status) == enabled ]] || { bad 'candidate theme not enabled'; exit 1; }
mtimes_before=$(candidate_mtimes); content_before=$(candidate_fingerprint)
sleep 1
"$HERE/scripts/theme" enable || { bad 'second candidate enable'; exit 1; }
[[ $(candidate_mtimes) == "$mtimes_before" && $(candidate_fingerprint) == "$content_before" ]] || { bad 'candidate enable changed installed mtimes or bytes'; exit 1; }
echo 'candidate enable: enabled; second enable preserved mtimes and bytes'
C open >/dev/null; sleep 1
S | jq -e '.themeState == "enabled" and all(.extras[]; .id != "matchTheme")' >/dev/null || { bad 'enabled menu still offers matchTheme'; exit 1; }
screenshot theme-menu-enabled
C close >/dev/null
injected_failure theme-enabled

# Both failure proofs use theme-tokyo-night, while no test window is open.
for theme_name in gruvbox tokyo-night flexoki-light; do
  step "candidate palette $theme_name"
  OMARCHY_THEME_SKIP_BACKGROUND=1 omarchy-theme-set "$theme_name" >/dev/null 2>&1 || { bad "set candidate palette $theme_name"; exit 1; }
  [[ $(<"$HOME/.local/state/omarchy/current/theme.name") == "$theme_name" ]] || { bad 'wrong current palette'; exit 1; }
  accent=$(palette accent); background=$(palette background); foreground=$(palette foreground); selection=$(palette selection)
  [[ -n $accent && -n $background && -n $foreground && -n $selection ]] || { bad 'invalid independent colors.toml'; exit 1; }
  for _ in $(seq 20); do theme_palette_matches && break; sleep 0.5; done
  theme_palette_matches || { bad "$theme_name palette/glyph/hash mismatch"; exit 1; }
  [[ $(classicui_values) == '{"Theme":"omarchy-input-menu","DarkTheme":"omarchy-input-menu"}' ]] || { bad 'classicui selection changed during theme switch'; exit 1; }
  echo "palette $theme_name: accent=$accent background=$background foreground=$foreground selection=$selection; hashed images verified"
  injected_failure "theme-$theme_name"
  # Open candidates after the switch; untouched old candidates retain their paint.
  open_test_window || { bad 'focus candidate screenshot window'; exit 1; }
  C switchTo fcitx-chewing '' >/dev/null; sleep 2
  [[ $(remote -n) == chewing ]] || { bad 'candidate screenshot is not Zhuyin'; exit 1; }
  focused && wtype su3 && focused && wtype -k Down || { bad 'candidate screenshot key guard'; exit 1; }
  sleep 0.8
  screenshot "candidate-$theme_name"
  focused && wtype -k Escape || { bad 'cancel screenshot composition'; exit 1; }
  remote -s keyboard-us || { bad 'restore ABC after candidate screenshot'; exit 1; }
  close_test_window || { bad 'close candidate screenshot window'; exit 1; }
done

step 'claimed candidate theme ownership'
"$HERE/scripts/theme" disable || { bad 'disable before claimed simulation'; exit 1; }
busctl --user --auto-start=no call "${CTL[@]}" SetConfig sv fcitx://config/addon/classicui 'a{sv}' 2 Theme s default DarkTheme s default || { bad 'simulate claimed theme'; exit 1; }
[[ $("$HERE/scripts/theme" status) == claimed ]] || { bad 'claimed state not detected'; exit 1; }
content_before=$(candidate_fingerprint)
"$HERE/scripts/theme" enable --auto || { bad 'auto-enable on claimed'; exit 1; }
[[ $(classicui_values) == '{"Theme":"default","DarkTheme":"default"}' && $(candidate_fingerprint) == "$content_before" ]] || { bad 'auto-enable changed claimed values or files'; exit 1; }
C open >/dev/null; sleep 1
S | jq -e '.themeState == "claimed" and any(.extras[]; .id == "matchTheme")' >/dev/null || { bad 'claimed menu lacks matchTheme'; exit 1; }
screenshot theme-menu-claimed
C close >/dev/null
"$HERE/scripts/theme" enable || { bad 'explicit claimed takeover'; exit 1; }
[[ $("$HERE/scripts/theme" status) == enabled ]] || { bad 'explicit takeover not enabled'; exit 1; }
"$HERE/scripts/theme" disable || { bad 'release explicit takeover'; exit 1; }
[[ $(classicui_values) == '{"Theme":"default","DarkTheme":"default"}' ]] || { bad 'claimed values not restored'; exit 1; }
echo 'claimed: auto left values/files unchanged; row present; explicit takeover round-tripped'
injected_failure theme-claimed

step 'candidate disable restores stock and removes artifacts'
busctl --user --auto-start=no call "${CTL[@]}" SetConfig sv fcitx://config/addon/classicui 'a{sv}' 2 \
  Theme s "$(jq -r .Theme <<<"$original_classicui")" DarkTheme s "$(jq -r .DarkTheme <<<"$original_classicui")" || { bad 'reset stock before disable check'; exit 1; }
"$HERE/scripts/theme" enable --auto && "$HERE/scripts/theme" disable || { bad 'stock candidate round-trip'; exit 1; }
[[ $(classicui_values) == "$original_classicui" && $("$HERE/scripts/theme" status) == free ]] && candidate_removed || { bad 'candidate disable left values/files'; exit 1; }
echo 'candidate disable: free; stock values restored; templates/hook/folder/state/lock removed'
OMARCHY_THEME_SKIP_BACKGROUND=1 omarchy-theme-set "$original_theme" >/dev/null 2>&1 || { bad 'restore original palette after candidate checks'; exit 1; }
injected_failure theme-disabled
# Preserve the existing idle step's owned-window positive control/close assertion.
open_test_window || { bad 'open final owned context before idle isolation'; exit 1; }
remote -s keyboard-us || bad 'ABC before idle isolation'

# Sample all plugin threads every 50 ms; the monotonic counter also catches
# processes too short-lived for /proc sampling.
idle_check() {
  local seconds=$1 start end baseline='' children child file i new=0 args
  local -A seen=()
  start=$(S) || return 1
  [[ $(jq -r .focused <<<"$start") == false && $(jq -r .focusKnown <<<"$start") == true ]] || { echo 'not idle at start'; return 1; }
  for file in /proc/"$shell_pid"/task/*/children; do
    [[ -e $file ]] || continue
    read -r children < "$file" || true
    baseline+=" $children"
  done
  for ((i=0; i<seconds*20; i++)); do
    for file in /proc/"$shell_pid"/task/*/children; do
      [[ -e $file ]] || continue
      children=''; read -r children < "$file" || true
      for child in $children; do
        if [[ " $baseline " != *" $child "* ]]; then
          new=1
          if [[ -z ${seen[$child]:-} ]]; then
            seen[$child]=1
            args=$(tr '\0' ' ' 2>/dev/null <"/proc/$child/cmdline" || true)
            echo "new shell child: pid=$child args=${args:-exited}"
          fi
        fi
      done
    done
    sleep 0.05
  done
  end=$(S) || return 1
  echo "idle: process starts $(jq -r .processStarts <<<"$start") -> $(jq -r .processStarts <<<"$end"); focus events $(jq -r .focusEvents <<<"$start") -> $(jq -r .focusEvents <<<"$end"); new sampled children=$new; focused=$(jq -r .focused <<<"$end")"
  [[ $new -eq 0 && $(jq -r .processStarts <<<"$start") == "$(jq -r .processStarts <<<"$end")" &&
     $(jq -r .focusEvents <<<"$start") == "$(jq -r .focusEvents <<<"$end")" &&
     $(jq -r .focused <<<"$end") == false ]]
}

monitors=$(hyprctl monitors -j 2>/dev/null) || { bad 'cannot read monitors; idle coverage unknown'; exit 1; }
monitor_count=$(jq -er 'if type == "array" and length > 0 then length else error("invalid monitors") end' <<<"$monitors") ||
  { bad 'invalid or empty monitor array; idle coverage unknown'; exit 1; }
if (( monitor_count > 1 )); then
  echo 'SKIP: idle-multi-monitor (IPC process counter covers one Panel instance)'
  skips+=(idle-multi-monitor)
else
  step 'isolate Input Menu from other bar widgets that poll with child processes'
  close_test_window || bad 'close test window before idle'
  C close >/dev/null
  jq --arg id "$T" '.bar.layout = {left: [], center: [], right: [.bar.layout.right[] | select(.id == $id)]}' \
    "$BACKUP/shell.json" > "$SCRATCH/isolated-shell.json" || { bad 'prepare isolated bar layout'; exit 1; }
  layout_changed=1
  cp "$SCRATCH/isolated-shell.json" "$SHELL_JSON" || { bad 'install isolated bar layout'; exit 1; }
  omarchy-restart-shell >/dev/null 2>&1 || { bad 'restart isolated bar'; exit 1; }
  sleep 10
  [[ $(S | jq -r .primary) == true && $(hyprctl clients -j | jq length) -eq 0 ]] || { bad 'Input Menu was not loaded alone with zero windows'; exit 1; }
  injected_failure isolated
  step 'idle positive control: a normal focused-window snapshot must fail the checker'
  shell_pid=$(pgrep -f "^quickshell -n -p $OMARCHY_PATH/shell$" | head -1)
  if [[ -n $shell_pid ]]; then
    idle_before=$(S); sleep 1; idle_after=$(S)
    [[ $(jq -r .focused <<<"$idle_before") == false && $(jq -r .focused <<<"$idle_after") == false &&
       $(jq -r .focusEvents <<<"$idle_before") == "$(jq -r .focusEvents <<<"$idle_after")" ]] || bad 'focus changed: cannot claim idle'
    (sleep 0.5; open_test_window && C open >/dev/null; C close >/dev/null; close_test_window) &
    if idle_check 4 > "$OUT/idle-positive.log"; then bad 'idle checker failed its positive control'
    else
      echo 'positive control rejected as expected:'
      grep '^idle:' "$OUT/idle-positive.log" || bad 'positive control did not record its counter delta'
      values=$(grep '^idle:' "$OUT/idle-positive.log" | sed -n 's/.*process starts \([0-9]*\) -> \([0-9]*\); focus events \([0-9]*\) -> \([0-9]*\).*/\1 \2 \3 \4/p')
      read -r start_count end_count start_focus end_focus <<<"$values"
      [[ -n $values && $end_count -gt $start_count && $end_focus -gt $start_focus ]] || bad 'positive control did not start a counted Process and a focus event'
    fi
    for ((i=0; i<20; i++)); do
      [[ $(hyprctl clients -j | jq length) -eq 0 && $(field .focused) == false ]] && break
      sleep 0.5
    done
    [[ $(hyprctl clients -j | jq length) -eq 0 && $(field .focused) == false ]] || bad 'positive control left a focused window'
    sleep 1
    step 'idle: 60 seconds without spawns or focus events'
    idle_check 60 || bad 'new plugin child/process or focus event during idle'
  else bad 'shell process not found'; fi
fi

# The EXIT trap restores state and prints ALL PASS or PASS WITH SKIPS.
