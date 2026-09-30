#!/bin/bash
# Sandbox test for scripts/theme: fake HOME, stubbed busctl and omarchy-theme-refresh.
# Runs anywhere with bash, jq, sed, sha256sum or shasum. Run: bash test/theme-check.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" FAKE_LOG="$T/log" FAKE_CLASSICUI="$T/classicui" FAKE_COLORS="$T/colors"
export INPUT_MENU_TEST=1
export INPUT_MENU_STATE_DIR="$HOME/.local/state/input-menu"
export OMARCHY_CURRENT_THEME_DIR="$HOME/current-theme"
export FCITX5_THEME_ROOT="$HOME/.local/share/fcitx5/themes"
mkdir -p "$HOME" "$T/bin"

cat >"$T/bin/busctl" <<'STUB'
#!/bin/bash
echo "busctl $*" >>"$FAKE_LOG"
case " $* " in *" --auto-start=no "*) ;; *) echo "$*" >>"$FAKE_LOG.bad" ;; esac
if [[ " $* " == *" State "* ]]; then [[ -n ${FCITX_DOWN:-} ]] && exit 1; echo "i 0"; exit 0; fi
if [[ " $* " == *" GetConfig "* ]]; then
  [[ -n ${FCITX_DOWN:-} ]] && exit 1
  [[ -n ${GETCONFIG_FAIL:-} ]] && exit 1
  if [[ -n ${GETCONFIG_BAD:-} ]]; then echo '{}'; exit 0; fi
  if [[ -f $FAKE_CLASSICUI ]]; then
    line=$(<"$FAKE_CLASSICUI"); t=${line%% *}; d=${line#* }
  else t=; d=; fi
  jq -nc --arg t "$t" --arg d "$d" '{type:"va(sa(sssva{sv}))",data:[{type:"a{sv}",data:{Theme:{type:"s",data:$t},DarkTheme:{type:"s",data:$d}}},[]]}'
  exit 0
fi
if [[ " $* " == *" SetConfig "* ]]; then
  [[ -n ${FCITX_DOWN:-} || -n ${SETCONFIG_FAIL:-} ]] && exit 1
  a=("$@"); t=; d=
  for i in "${!a[@]}"; do [[ ${a[i]} == Theme ]] && t=${a[i+2]}; [[ ${a[i]} == DarkTheme ]] && d=${a[i+2]}; done
  echo "$t $d" >"$FAKE_CLASSICUI"
  mkdir -p "$HOME/.config/fcitx5/conf"; printf 'Theme=%s\nDarkTheme=%s\n' "$t" "$d" >"$HOME/.config/fcitx5/conf/classicui.conf"   # real fcitx5 saves it
  exit 0
fi
if [[ " $* " == *" ReloadAddonConfig "* ]]; then echo reload >>"$FAKE_LOG.reload"; exit 0; fi
exit 0
STUB
cat >"$T/bin/omarchy-theme-refresh" <<'STUB'
#!/bin/bash
[[ -n ${REFRESH_FAIL:-} ]] && exit 1
mkdir -p "$OMARCHY_CURRENT_THEME_DIR"
for f in "$HOME"/.config/omarchy/themed/*.tpl; do
  [[ -e $f ]] || continue
  out="$OMARCHY_CURRENT_THEME_DIR/$(basename "${f%.tpl}")"; cp "$f" "$out"
  while IFS='=' read -r k v; do sed "s|{{ $k }}|$v|g" "$out" >"$out.x" && mv "$out.x" "$out"; done <"$FAKE_COLORS"
done
if [[ -n ${REFRESH_AFTER_RENDER_FAIL:-} ]]; then
  echo 'refresh failed after rendering' >>"$FAKE_LOG"
  exit 1
fi
STUB
# Inspect the rename boundary, not just the final directory: all referenced images
# must exist before theme.conf is published, and old images must survive until then.
REAL_MV="$(command -v mv)"; export REAL_MV
cat >"$T/bin/mv" <<'STUB'
#!/bin/bash
for dest; do :; done
if [[ $dest == "$FCITX5_THEME_ROOT/omarchy-input-menu/theme.conf" ]]; then
  src=$1; [[ $src == -f ]] && src=$2
  dir=${dest%/*}
  while IFS= read -r image; do
    [[ -f $dir/$image ]] || { echo "missing image $image" >>"$FAKE_LOG.order"; exit 1; }
  done < <(sed -n 's/^Image=//p' "$src")
  if [[ -f $dest ]]; then
    while IFS= read -r image; do
      [[ -f $dir/$image ]] || { echo "old image removed early $image" >>"$FAKE_LOG.order"; exit 1; }
    done < <(sed -n 's/^Image=//p' "$dest")
  fi
  [[ -n ${PUBLISH_FAIL:-} ]] && exit 1
fi
exec "$REAL_MV" "$@"
STUB
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"

mkdir -p "$HOME/plugin/scripts" "$HOME/plugin/theme"
cp "$HERE/scripts/theme" "$HOME/plugin/scripts/"
cp "$HERE"/theme/*.tpl "$HOME/plugin/theme/"
S="$HOME/plugin/scripts/theme"; D="$FCITX5_THEME_ROOT/omarchy-input-menu"
fails=0
check() { if [[ $2 != "$3" ]]; then echo "FAIL: $1: got [$2] want [$3]"; fails=1; fi; }
count() { local n=0 f; for f; do [[ ! -e $f ]] || n=$((n + 1)); done; echo "$n"; }
colors() { printf 'accent=%s\nbackground=%s\nforeground=%s\nselection=%s\nmuted=%s\n' "$1" "$2" "$3" "$4" "$5" >"$FAKE_COLORS"; }
setc() { echo "$1 $2" >"$FAKE_CLASSICUI"; }
cur() { cat "$FAKE_CLASSICUI"; }
reset() { rm -rf "$HOME/.config" "$HOME/.local" "$OMARCHY_CURRENT_THEME_DIR" "$FAKE_LOG" "$FAKE_LOG.reload"; unset FCITX_DOWN; }
border() { sed -n 's/^BorderColor=//p' "$D/theme.conf" | head -1; }

# 0. a HOME with a trailing slash is still a home (the plugin lives under it)
reset; colors '#7aa2f7' '#1a1b26' '#a9b1d6' '#292e42' '#414868'
setc default default-dark
HOME="$HOME/" "$S" enable --auto >/dev/null 2>&1;   check "trailing-slash HOME enable rc" "$?" 0
check "trailing-slash HOME took over" "$(cur)" "omarchy-input-menu omarchy-input-menu"
reset

# 1. free: unset and stock values
reset; colors '#7aa2f7' '#1a1b26' '#a9b1d6' '#292e42' '#414868'
setc default default-dark;  check "status free" "$($S status)" free
rm -f "$FAKE_CLASSICUI";    check "status free (unset, no conf)" "$($S status)" free
setc default default-dark
$S enable --auto >/dev/null;                    check "auto enable rc" "$?" 0
check "theme after auto enable" "$(cur)" "omarchy-input-menu omarchy-input-menu"
check "status enabled" "$($S status)" enabled
check "border from accent" "$(border)" '#7aa2f7'
check "previous recorded" "$(jq -r '.previous.Theme+" "+.previous.DarkTheme' "$INPUT_MENU_STATE_DIR/theme.json")" "default default-dark"
n=$(ls "$D"/*.svg | wc -l | tr -d ' '); check "four glyphs" "$n" 4
grep -q '^Image=prev-[0-9a-f]\{8\}\.svg$' "$D/theme.conf" || { echo "FAIL: Image= not hashed"; fails=1; }
grep -q '^Image=prev\.svg' "$D/theme.conf" && { echo "FAIL: unhashed Image= left"; fails=1; }
grep -q 'stroke="#a9b1d6"' "$D"/prev-*.svg || { echo "FAIL: glyph not foreground colored"; fails=1; }
[[ -x $HOME/.config/omarchy/hooks/theme-set.d/input-menu || -f $HOME/.config/omarchy/hooks/theme-set.d/input-menu ]] || { echo "FAIL: hook missing"; fails=1; }
$S status --json | jq -e '.state=="enabled" and .theme=="omarchy-input-menu"' >/dev/null || { echo "FAIL: status --json"; fails=1; }

# 2. theme change through the hook: new colors, new hashed names, stale glyphs gone, reload asked, no temp files
before=$(ls "$D"/*.svg | sort | tr '\n' ' ')
colors '#205EA6' '#FFFCF0' '#100F0F' '#e6e4d9' '#b7b5ac'
omarchy-theme-refresh; : >"$FAKE_LOG.reload"
bash "$HOME/.config/omarchy/hooks/theme-set.d/input-menu"; check "hook rc" "$?" 0
check "border follows theme" "$(border)" '#205EA6'
after=$(ls "$D"/*.svg | sort | tr '\n' ' ')
[[ $before != "$after" ]] || { echo "FAIL: glyph names did not change with the colors"; fails=1; }
check "four glyphs after change" "$(ls "$D"/*.svg | wc -l | tr -d ' ')" 4
grep -q 'stroke="#100F0F"' "$D"/prev-*.svg || { echo "FAIL: light glyph color"; fails=1; }
[[ -s $FAKE_LOG.reload ]] || { echo "FAIL: reload not requested"; fails=1; }
check "no temp files" "$(count "$D"/.theme.conf.*)" 0

# 3. enable twice keeps both previous values and every installed file/directory mtime.
timestamps() {
  local f
  while IFS= read -r f; do
    if [[ $(uname -s) == Darwin ]]; then stat -f '%m %N' "$f"; else stat -c '%Y %n' "$f"; fi
  done < <(find "$D" "$HOME/.config/omarchy/themed" -print | sort; echo "$HOME/.config/omarchy/hooks/theme-set.d/input-menu")
}
mtimes=$(timestamps); sleep 1
$S enable >/dev/null
check "re-enable keeps installed mtimes" "$(timestamps)" "$mtimes"
check "previous kept on re-enable" "$(jq -r '.previous.Theme' "$INPUT_MENU_STATE_DIR/theme.json")" default

# 4. disable restores and removes everything (including a legacy apply lock).
: >"$INPUT_MENU_STATE_DIR/lock"
$S disable >/dev/null; check "disable rc" "$?" 0
check "restored" "$(cur)" "default default-dark"
[[ ! -e $D && ! -e $INPUT_MENU_STATE_DIR/theme.json && ! -e $HOME/.config/omarchy/hooks/theme-set.d/input-menu ]] || { echo "FAIL: files left"; fails=1; }
check "templates removed" "$(count "$HOME"/.config/omarchy/themed/*input-menu*)" 0
[[ ! -e $INPUT_MENU_STATE_DIR/lock ]] || { echo "FAIL: theme lock left after disable"; fails=1; }
$S apply; check "disabled apply rc" "$?" 0
[[ ! -e $D ]] || { echo "FAIL: disabled apply recreated the theme folder"; fails=1; }

# 5. claimed: --auto leaves it, explicit enable takes over and disable restores it
reset; colors '#7aa2f7' '#1a1b26' '#a9b1d6' '#292e42' '#414868'
setc omarchy omarchy; check "status claimed" "$($S status)" claimed
setc default my-theme; check "status claimed (dark only)" "$($S status)" claimed
setc material material
out=$($S enable --auto); check "auto on claimed rc" "$?" 0
check "claimed untouched" "$(cur)" "material material"; [[ ! -e $D ]] || { echo "FAIL: auto created files on claimed"; fails=1; }
[[ $out == *"scripts/theme enable"* ]] || { echo "FAIL: auto on claimed gives no hint"; fails=1; }
setc omarchy-input-menu default-dark; $S enable >/dev/null; $S disable >/dev/null
check "half-ours restores stock values" "$(cur)" "default default-dark"
setc material material
$S enable >/dev/null; check "explicit takeover" "$(cur)" "omarchy-input-menu omarchy-input-menu"
$S disable >/dev/null; check "restored user's theme" "$(cur)" "material material"

# 6. someone else changed Theme after us: disable leaves it, still cleans our files
reset; colors '#7aa2f7' '#1a1b26' '#a9b1d6' '#292e42' '#414868'
setc default default-dark; $S enable --auto >/dev/null
setc other-plugin other-plugin; $S disable >/dev/null
check "foreign value kept" "$(cur)" "other-plugin other-plugin"; [[ ! -e $D ]] || { echo "FAIL: folder left"; fails=1; }
setc default default-dark; $S enable --auto >/dev/null
setc omarchy-input-menu other-dark; $S disable >/dev/null
check "only our half restored" "$(cur)" "default other-dark"

# 7. fcitx5 down: apply writes files without reload; enable sets nothing; disable refuses and keeps files
reset; colors '#7aa2f7' '#1a1b26' '#a9b1d6' '#292e42' '#414868'
setc default default-dark; export FCITX_DOWN=1
$S enable --auto >/dev/null; check "enable while down rc" "$?" 0
check "nothing set while down" "$(cur)" "default default-dark"; [[ ! -e $INPUT_MENU_STATE_DIR/theme.json ]] || { echo "FAIL: state recorded while down"; fails=1; }
unset FCITX_DOWN; $S enable >/dev/null; export FCITX_DOWN=1
$S disable >/dev/null 2>&1; check "disable while down refuses" "$?" 1
[[ -e $D/theme.conf ]] || { echo "FAIL: folder removed while fcitx5 down"; fails=1; }
unset FCITX_DOWN

# 8. nothing rendered yet: apply is a no-op
reset; $S apply; check "apply without render rc" "$?" 0; [[ ! -e $D ]] || { echo "FAIL: apply created files without a render"; fails=1; }

# 9. Live unset Theme must not hide a claimed DarkTheme behind a stale disk config.
reset; colors '#7aa2f7' '#1a1b26' '#a9b1d6' '#292e42' '#414868'
setc default default-dark; $S enable >/dev/null; $S disable >/dev/null
setc '' my-dark
check "live unset Theme, claimed DarkTheme" "$($S status)" claimed
$S enable --auto >/dev/null; check "live dark claim not taken over" "$(cur)" ' my-dark'

# 10. A failed live config read must never fall back to stale stock values.
setc default default-dark; $S enable >/dev/null
export GETCONFIG_FAIL=1
$S enable --auto >/dev/null 2>&1; check "failed GetConfig refuses enable" "$?" 1
$S disable >/dev/null 2>&1; check "failed GetConfig refuses disable" "$?" 1
[[ -e $D/theme.conf && -e $INPUT_MENU_STATE_DIR/theme.json ]] || { echo "FAIL: read error removed owned files"; fails=1; }
unset GETCONFIG_FAIL
export GETCONFIG_BAD=1
$S enable --auto >/dev/null 2>&1; check "malformed GetConfig refuses enable" "$?" 1
$S disable >/dev/null 2>&1; check "malformed GetConfig refuses disable" "$?" 1
[[ -e $D/theme.conf && -e $INPUT_MENU_STATE_DIR/theme.json ]] || { echo "FAIL: malformed config removed owned files"; fails=1; }
unset GETCONFIG_BAD

# 11. Restoring must succeed before any owned files disappear.
export SETCONFIG_FAIL=1
$S disable >/dev/null 2>&1; check "failed restore refuses disable" "$?" 1
[[ -e $D/theme.conf && -e $INPUT_MENU_STATE_DIR/theme.json && -e $HOME/.config/omarchy/hooks/theme-set.d/input-menu ]] || { echo "FAIL: restore error removed owned files"; fails=1; }
unset SETCONFIG_FAIL

# 12. While down, apply still publishes colors but never asks for a reload.
export FCITX_DOWN=1
colors '#205EA6' '#FFFCF0' '#100F0F' '#e6e4d9' '#b7b5ac'; omarchy-theme-refresh
: >"$FAKE_LOG.reload"
$S apply; check "apply while down rc" "$?" 0
check "apply while down writes colors" "$(border)" '#205EA6'
[[ ! -s $FAKE_LOG.reload ]] || { echo "FAIL: apply while down requested reload"; fails=1; }
unset FCITX_DOWN

# 13. Incomplete render and failed publication leave the old config/images intact.
old=$(<"$D/theme.conf"); images=$(ls "$D"/*.svg | sort)
rm "$OMARCHY_CURRENT_THEME_DIR/input-menu-fcitx5-prev.svg"
$S apply >/dev/null 2>&1; check "partial render refuses apply" "$?" 1
check "partial render preserves config" "$(<"$D/theme.conf")" "$old"
check "partial render preserves glyphs" "$(ls "$D"/*.svg | sort)" "$images"
bash "$HOME/.config/omarchy/hooks/theme-set.d/input-menu"; check "hook ignores apply failure" "$?" 0
# Change only accent so publication is required without changing the glyph set.
colors '#abcdef' '#FFFCF0' '#100F0F' '#e6e4d9' '#b7b5ac'
omarchy-theme-refresh; export PUBLISH_FAIL=1
$S apply >/dev/null 2>&1; check "failed rename refuses apply" "$?" 1
check "failed rename preserves config" "$(<"$D/theme.conf")" "$old"
check "failed rename preserves glyphs" "$(ls "$D"/*.svg | sort)" "$images"
check "failed rename cleans temp files" "$(count "$D"/.theme.conf.*)" 0
unset PUBLISH_FAIL

# 14. Never select a nonexistent theme if refresh produced nothing.
reset; setc default default-dark; export REFRESH_FAIL=1
$S enable >/dev/null 2>&1; check "missing render refuses enable" "$?" 1
check "missing render leaves selection" "$(cur)" "default default-dark"
unset REFRESH_FAIL

# 15. Hook stays harmless if the plugin has been removed (quoted path included).
reset; colors '#7aa2f7' '#1a1b26' '#a9b1d6' '#292e42' '#414868'; setc default default-dark
copy="$HOME/plugin path's copy"; mkdir -p "$copy/scripts" "$copy/theme"
cp "$S" "$copy/scripts/theme"; chmod +x "$copy/scripts/theme"; cp "$HERE"/theme/*.tpl "$copy/theme/"
"$copy/scripts/theme" enable >/dev/null
bash "$HOME/.config/omarchy/hooks/theme-set.d/input-menu"; check "hook with quoted path" "$?" 0
rm "$copy/scripts/theme"
bash "$HOME/.config/omarchy/hooks/theme-set.d/input-menu"; check "hook with removed plugin" "$?" 0

# 16. A stale render must not satisfy enable; a fresh render wins over refresh's exit status.
reset; colors '#7aa2f7' '#1a1b26' '#a9b1d6' '#292e42' '#414868'; setc default default-dark
$S enable >/dev/null; $S disable >/dev/null
check "stale render exists" "$(sed -n 's/^BorderColor=//p' "$OMARCHY_CURRENT_THEME_DIR/input-menu-fcitx5.conf" | head -1)" '#7aa2f7'
printf 'keep\n' >"$OMARCHY_CURRENT_THEME_DIR/input-menu-fcitx5.conf.keep"
printf 'keep\n' >"$OMARCHY_CURRENT_THEME_DIR/input-menu-unrelated.svg"
colors '#205EA6' '#FFFCF0' '#100F0F' '#e6e4d9' '#b7b5ac'; setc material material
: >"$FAKE_LOG"; export REFRESH_FAIL=1
$S enable >/dev/null 2>&1; check "stale render refuses enable" "$?" 1
check "stale render leaves selection" "$(cur)" "material material"
[[ ! -e $D ]] || { echo "FAIL: stale colors published"; fails=1; }
grep -qE ' (SetConfig|ReloadAddonConfig) ' "$FAKE_LOG" && { echo "FAIL: failed refresh changed classicui"; fails=1; }
check "stale rendered config removed" "$(count "$OMARCHY_CURRENT_THEME_DIR/input-menu-fcitx5.conf")" 0
check "stale rendered glyphs removed" "$(count "$OMARCHY_CURRENT_THEME_DIR"/input-menu-fcitx5-*.svg)" 0
check "unrelated rendered files kept" "$(count "$OMARCHY_CURRENT_THEME_DIR/input-menu-fcitx5.conf.keep" "$OMARCHY_CURRENT_THEME_DIR/input-menu-unrelated.svg")" 2
previous=$(<"$INPUT_MENU_STATE_DIR/theme.json")
check "failed refresh records previous selection" "$(jq -r '.previous.Theme+" "+.previous.DarkTheme' "$INPUT_MENU_STATE_DIR/theme.json")" "material material"
unset REFRESH_FAIL; setc intervening intervening; export REFRESH_AFTER_RENDER_FAIL=1
$S enable >/dev/null; check "fresh render with failed refresh enables" "$?" 0
grep -q '^refresh failed after rendering$' "$FAKE_LOG" || { echo "FAIL: refresh did not fail after rendering"; fails=1; }
check "fresh colors published" "$(border)" '#205EA6'
check "fresh render claims selection" "$(cur)" "omarchy-input-menu omarchy-input-menu"
check "retry keeps previous values" "$(<"$INPUT_MENU_STATE_DIR/theme.json")" "$previous"
unset REFRESH_AFTER_RENDER_FAIL
$S disable >/dev/null; check "retry restores first recorded selection" "$(cur)" "material material"

# Queue apply and disable on the same persistent directory lock (Linux).
if command -v flock >/dev/null; then
  $S enable >/dev/null
  (exec 9<"$INPUT_MENU_STATE_DIR"; flock 9; touch "$T/locked"; while [[ ! -e $T/release ]]; do sleep 0.02; done) &
  locker=$!
  for _ in {1..100}; do [[ ! -e $T/locked ]] || break; sleep 0.02; done
  [[ -e $T/locked ]] || { echo "FAIL: concurrency lock not acquired"; fails=1; }
  $S disable >/dev/null & disable_pid=$!
  $S apply >/dev/null & apply_pid=$!
  sleep 0.5; touch "$T/release"
  wait "$locker"; check "lock holder rc" "$?" 0
  wait "$disable_pid"; check "queued disable rc" "$?" 0
  wait "$apply_pid"; check "queued apply rc" "$?" 0
  [[ ! -e $D && ! -e $INPUT_MENU_STATE_DIR/theme.json ]] || { echo "FAIL: queued apply undid disable"; fails=1; }
fi

# Untrusted hook locations are refused before writing anything.
reset; setc default default-dark
outside="$T/outside"; mkdir -p "$outside/scripts" "$outside/theme"
cp "$S" "$outside/scripts/theme"; cp "$HERE"/theme/*.tpl "$outside/theme/"
out=$("$outside/scripts/theme" enable 2>&1); check 'outside HOME refused' "$?" 1
[[ $out == *HOME* ]] || { echo 'FAIL: untrusted hook has no reason'; fails=1; }
[[ ! -e $HOME/.config && ! -e $HOME/.local ]] || { echo 'FAIL: untrusted hook wrote files'; fails=1; }

# Production ignores all three environment seams, including deletion targets.
reset; setc default default-dark
foreign="$T/foreign"; mkdir -p "$foreign/state" "$foreign/render" "$foreign/themes/omarchy-input-menu"
echo '{"previous":{"Theme":"default","DarkTheme":"default-dark"}}' >"$foreign/state/theme.json"
echo keep >"$foreign/render/input-menu-fcitx5.conf"
echo keep >"$foreign/themes/omarchy-input-menu/keep"
INPUT_MENU_TEST=0 INPUT_MENU_STATE_DIR="$foreign/state" OMARCHY_CURRENT_THEME_DIR="$foreign/render" FCITX5_THEME_ROOT="$foreign/themes" "$S" disable >/dev/null
check 'production ignores state seam' "$(count "$foreign/state/theme.json")" 1
check 'production ignores theme seam' "$(count "$foreign/themes/omarchy-input-menu/keep")" 1
# With test seams enabled, removal still refuses paths outside HOME.
INPUT_MENU_STATE_DIR="$foreign/state" FCITX5_THEME_ROOT="$foreign/themes" "$S" disable >/dev/null 2>&1
check 'outside state not removed' "$(count "$foreign/state/theme.json")" 1
check 'outside theme not removed' "$(count "$foreign/themes/omarchy-input-menu/keep")" 1
export REFRESH_FAIL=1
INPUT_MENU_TEST=0 INPUT_MENU_STATE_DIR="$foreign/state" OMARCHY_CURRENT_THEME_DIR="$foreign/render" FCITX5_THEME_ROOT="$foreign/themes" "$S" enable >/dev/null 2>&1
check 'production ignores rendered seam' "$(<"$foreign/render/input-menu-fcitx5.conf")" keep
[[ -f $HOME/.local/state/input-menu/theme.json ]] || { echo 'FAIL: production state not at default'; fails=1; }
unset REFRESH_FAIL

# Symlink destinations (including dangling ones) survive enable and disable.
reset; setc default default-dark
hook="$HOME/.config/omarchy/hooks/theme-set.d/input-menu"
tpl="$HOME/.config/omarchy/themed/input-menu-fcitx5.conf.tpl"
mkdir -p "${hook%/*}" "${tpl%/*}"
cp "$HERE/theme/input-menu-fcitx5.conf.tpl" "$T/custom.tpl"
echo '# custom template' >>"$T/custom.tpl"
echo '# keep hook' >"$T/custom-hook"
ln -s "$T/custom.tpl" "$tpl"; ln -s "$T/custom-hook" "$hook"
ln -s "$T/missing" "${tpl%/*}/input-menu-fcitx5-extra.tpl"
before=$(cksum "$T/custom.tpl" "$T/custom-hook")
out=$("$S" enable 2>&1); check 'symlink enable rc' "$?" 0
[[ $out == *symlink* ]] || { echo 'FAIL: enable symlinks need warning'; fails=1; }
[[ -L $tpl && -L $hook ]] || { echo 'FAIL: enable replaced symlinks'; fails=1; }
out=$("$S" disable 2>&1); check 'symlink disable rc' "$?" 0
[[ $out == *symlink* ]] || { echo 'FAIL: disable symlinks need warning'; fails=1; }
[[ -L $tpl && -L $hook && -L ${tpl%/*}/input-menu-fcitx5-extra.tpl ]] || { echo 'FAIL: disable removed symlinks'; fails=1; }
check 'symlink targets untouched' "$(cksum "$T/custom.tpl" "$T/custom-hook")" "$before"
reset; setc default default-dark; "$S" enable >/dev/null
grep -q '\[\[.*-O ' "$hook" || { echo 'FAIL: hook lacks owner guard'; fails=1; }

# 18. Symlinked ancestors or destinations never redirect writes or removals (managed scope is checked on the real path).
tree_sum() { (cd "$1" && find . -type f | sort | while read -r f; do cksum "$f"; done); }
link_scene() {   # $1 what to link: root | dest | conf | glyph | themed | hookdir
  reset; colors '#7aa2f7' '#1a1b26' '#a9b1d6' '#292e42' '#414868'; setc default default-dark
  "$S" enable >/dev/null
  rm -rf "$HOME/elsewhere"; mkdir -p "$HOME/elsewhere"; printf 'victim\n' >"$HOME/elsewhere/keep.txt"
  case $1 in
    root)  rm -rf "$FCITX5_THEME_ROOT"; mkdir -p "$HOME/elsewhere/themes"; ln -s "$HOME/elsewhere/themes" "$FCITX5_THEME_ROOT"
           mkdir -p "$HOME/elsewhere/themes/omarchy-input-menu"; printf 'victim\n' >"$HOME/elsewhere/themes/omarchy-input-menu/theme.conf" ;;
    dest)  rm -rf "$D"; mkdir -p "$HOME/elsewhere/dest"; printf 'victim\n' >"$HOME/elsewhere/dest/theme.conf"; ln -s "$HOME/elsewhere/dest" "$D" ;;
    conf)  cp "$HOME/elsewhere/keep.txt" "$HOME/elsewhere/conf-target"; rm -f "$D/theme.conf"; ln -s "$HOME/elsewhere/conf-target" "$D/theme.conf" ;;
    glyph) cp "$HOME/elsewhere/keep.txt" "$HOME/elsewhere/glyph-target"; for f in "$D"/prev-*.svg; do rm -f "$f"; ln -s "$HOME/elsewhere/glyph-target" "$f"; done ;;
    themed) mkdir -p "$HOME/elsewhere/themed"; cp "$THEMED"/*.tpl "$HOME/elsewhere/themed/"; rm -rf "$THEMED"; ln -s "$HOME/elsewhere/themed" "$THEMED" ;;
    hookdir) mkdir -p "$HOME/elsewhere/hooks"; cp "$HOOKS"/* "$HOME/elsewhere/hooks/"; rm -rf "$HOOKS"; ln -s "$HOME/elsewhere/hooks" "$HOOKS" ;;
  esac
  tree_sum "$HOME/elsewhere" >"$T/elsewhere.before"
}
THEMED="$HOME/.config/omarchy/themed"; HOOKS="$HOME/.config/omarchy/hooks/theme-set.d"
for what in root dest conf glyph; do
  link_scene $what; colors '#ff0000' '#000000' '#ffffff' '#111111' '#222222'
  out=$("$S" apply 2>&1) && rc=0 || rc=$?
  [[ $rc -ne 0 && $out == *symlink* ]] || { echo "FAIL: apply through linked $what: rc=$rc out=$out"; fails=1; }
  check "apply linked $what left target untouched" "$(tree_sum "$HOME/elsewhere")" "$(cat "$T/elsewhere.before")"
done
for what in root dest themed hookdir; do
  link_scene $what
  "$S" disable >/dev/null 2>&1 || true
  check "disable linked $what left target untouched" "$(tree_sum "$HOME/elsewhere")" "$(cat "$T/elsewhere.before")"
done
for what in themed hookdir; do
  link_scene $what; rm -f "$INPUT_MENU_STATE_DIR/theme.json"
  setc default default-dark
  out=$("$S" enable 2>&1) && rc=0 || rc=$?
  [[ $rc -ne 0 && $out == *symlink* ]] || { echo "FAIL: enable through linked $what: rc=$rc out=$out"; fails=1; }
  check "enable linked $what left target untouched" "$(tree_sum "$HOME/elsewhere")" "$(cat "$T/elsewhere.before")"
done
reset

# 17. Never D-Bus-activate fcitx5; publish only after all referenced files exist.
[[ ! -e $FAKE_LOG.order ]] || { echo "FAIL: theme.conf published before images:"; cat "$FAKE_LOG.order"; fails=1; }
[[ ! -e $FAKE_LOG.bad ]] || { echo "FAIL: busctl call without --auto-start=no:"; cat "$FAKE_LOG.bad"; fails=1; }

if (( fails )); then echo "FAILED"; exit 1; fi
echo ok
