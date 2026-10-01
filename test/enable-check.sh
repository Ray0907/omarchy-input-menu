#!/bin/bash
# Sandbox enable's failed rebuilds and tray ownership transaction.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" ENABLE_TEST="$T"
mkdir -p "$T/bin" "$T/scripts"
cp "$HERE/scripts/enable" "$T/scripts/enable"
printf '#!/bin/bash\necho real-theme >"$ENABLE_TEST/real-theme"\n[[ ${THEME_FAIL:-} != 1 ]] || { echo "theme failure reason" >&2; exit 1; }\nexit 0\n' >"$T/scripts/theme"
cat >"$T/bin/busctl" <<'STUB'
#!/bin/bash
echo "$*" >>"$ENABLE_TEST/bus"
[[ " $* " == *' --auto-start=no '* ]] || echo bad >"$ENABLE_TEST/activation"
a=("$@")
for i in "${!a[@]}"; do
  if [[ ${a[i]} == get-property ]]; then
    [[ ${a[i+1]} == -- ]] || echo 'missing --' >>"$ENABLE_TEST/names"
    if [[ ${a[i+1]} == -- ]]; then n=${a[i+2]}; p=${a[i+3]}; else n=${a[i+1]}; p=${a[i+2]}; fi
    [[ $n =~ ^[:A-Za-z0-9._-]+$ && $p =~ ^/[A-Za-z0-9_/]*$ ]] || echo 'hostile entry' >>"$ENABLE_TEST/names"
  fi
done
case "$*" in
  *RegisteredStatusNotifierItems*)
    if [[ ${HOSTILE:-} == 1 ]]; then echo '{"data":["-H.x /x","*",":1.9/bad-path",":1.9/StatusNotifierItem"]}'
    elif [[ ${NO_SNI:-} == 1 && -e $ENABLE_TEST/wait-sni ]]; then echo '{"data":[]}'
    else echo '{"data":[":1.9/StatusNotifierItem"]}'; fi ;;
  *'org.kde.StatusNotifierItem Id'*) echo 's "Fcitx"' ;;
esac
STUB
cat >"$T/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >>"$ENABLE_TEST/systemctl"
case "$*" in
  *' cat '*) printf '# /stock\nExecStart=%s\n' "${CAT_LINE:-/usr/bin/fcitx5 --disable notificationitem}" ;;
  *' restart '*) [[ ${FAIL_RESTART:-} != 1 ]] || exit 1 ;;
  *' show '*)
    if [[ ${SWAP_DROPIN:-} == 1 && ! -e $ENABLE_TEST/dropin-swapped ]]; then
      "$REAL_MV" "$HOME/.config/systemd/user" "$ENABLE_TEST/original-user"
      ln -s "$ENABLE_TEST/foreign-user" "$HOME/.config/systemd/user"
      touch "$ENABLE_TEST/dropin-swapped"
    fi
    [[ ${UNREADABLE:-} != 1 ]] || exit 1
    printf '{ path=/usr/bin/fcitx5 ; argv[]=%s ; ignore_errors=%s ; }\n' "${FCITX_ARGV:-/usr/bin/fcitx5 --disable notificationitem}" "${IGNORE_ERRORS:-no}"
    ;;
esac
STUB
REAL_RM=$(command -v rm); export REAL_RM
cat >"$T/bin/rm" <<'STUB'
#!/bin/bash
if [[ ${FAIL_ROLLBACK_RM:-} == 1 && $1 == -f ]]; then
  echo "$*" >>"$ENABLE_TEST/rollback-rm"
  for dest; do :; done
  [[ $dest != */zz-input-menu.conf && $dest != */input-menu-enable.json ]] || exit 1
fi
exec "$REAL_RM" "$@"
STUB
REAL_MV=$(command -v mv); export REAL_MV
cat >"$T/bin/mv" <<'STUB'
#!/bin/bash
a=("$@"); n=${#a[@]}; src=${a[n-2]}; dest=${a[n-1]}
if [[ $dest == */zz-input-menu.conf ]]; then
  [[ ${FAIL_ROLLBACK_MV:-} != 1 || $src != */.previous.* ]] || exit 1
  [[ ${src%/*} == "${dest%/*}" ]] || echo bad >"$ENABLE_TEST/atomic"
  if [[ ${FAIL_PUBLISH:-} == 1 && ! -e $ENABLE_TEST/mv-failed ]]; then touch "$ENABLE_TEST/mv-failed"; exit 1; fi
fi
if [[ $dest == */input-menu-enable.json && ${FAIL_STATE:-} == 1 ]]; then exit 1; fi
exec "$REAL_MV" "$@"
STUB
cat >"$T/bin/sleep" <<'STUB'
#!/bin/bash
if [[ ${SWAP_STATE:-} == 1 && ! -e $ENABLE_TEST/state-swapped ]]; then
  mkdir -p "$HOME/.local"
  [[ ! -d $HOME/.local/state ]] || "$REAL_MV" "$HOME/.local/state" "$ENABLE_TEST/original-state"
  ln -s "$ENABLE_TEST/foreign-state" "$HOME/.local/state"
  touch "$ENABLE_TEST/state-swapped"
fi
STUB
cat >"$T/bin/omarchy-bar" <<'STUB'
#!/bin/bash
echo "$*" >>"$ENABLE_TEST/bar"
jq -e '.addedHidden == true' "$HOME/.local/state/input-menu-enable.json" >/dev/null 2>&1 || echo missing >"$ENABLE_TEST/state-order"
[[ ${FAIL_BAR:-} != 1 ]]
STUB
chmod +x "$T/bin/"* "$T/scripts/"*
export PATH="$T/bin:$PATH"
DROPIN="$HOME/.config/systemd/user/omarchy-fcitx5.service.d/zz-input-menu.conf"
STATE="$HOME/.local/state/input-menu-enable.json"
fails=0
check() { if [[ $2 != "$3" ]]; then echo "FAIL: $1: got [$2] want [$3]"; fails=1; fi; }
reset() {
  rm -rf "$HOME"; rm -f "$T/activation" "$T/atomic" "$T/mv-failed" "$T/bar" "$T/state-order" "$T/systemctl"
  mkdir -p "${DROPIN%/*}" "$HOME/.config/omarchy"
  printf '[Service]\nExecStart=\nExecStart=/usr/bin/fcitx5 -r\n\n' >"$DROPIN"
  cp "$DROPIN" "$T/previous"
  echo '{"bar":{"layout":{"right":[{"id":"omarchy.tray","hidden":[]}]}}}' >"$HOME/.config/omarchy/shell.json"
}
restored() {
  cmp -s "$T/previous" "$DROPIN" || { echo "FAIL: $1 lost previous drop-in bytes"; fails=1; }
  check "$1 reload after restore" "$(tail -1 "$T/systemctl")" '--user daemon-reload'
}
reset
UNREADABLE=1 "$T/scripts/enable" >"$T/output" 2>&1
check 'unreadable exit' "$?" 1; restored unreadable
grep -q 'ExecStart' "$T/output" || { echo 'FAIL: unreadable lacks diagnostic'; fails=1; }
reset
FAIL_PUBLISH=1 "$T/scripts/enable" >"$T/output" 2>&1
check 'publish failure exit' "$?" 1; restored publish
for argv in '/usr/bin/fcitx5 %h' '/usr/bin/fcitx5 $HOME' '/usr/bin/fcitx5 ; x' '/usr/bin/fcitx5 "x"'; do
  reset
  FCITX_ARGV="$argv" "$T/scripts/enable" >"$T/output" 2>&1
  check "unsupported $argv exit" "$?" 1; restored "$argv"
  grep -q 'Cannot preserve.*ExecStart' "$T/output" || { echo "FAIL: unsafe argv lacks diagnostic: $argv"; fails=1; }
done
reset
IGNORE_ERRORS=yes "$T/scripts/enable" >"$T/output" 2>&1
check 'ignore_errors exit' "$?" 1; restored ignore_errors
grep -q 'Cannot preserve.*ignore_errors' "$T/output" || { echo 'FAIL: ignore_errors lacks diagnostic'; fails=1; }
for old in absent present; do
  reset; rm "$DROPIN"
  if [[ $old == present ]]; then mkdir -p "${STATE%/*}"; printf '{"addedHidden":false}\n\n' >"$STATE"; cp "$STATE" "$T/old-state"; fi
  FAIL_BAR=1 "$T/scripts/enable" >"$T/output" 2>&1
  check "failed hide $old exit" "$?" 1
  [[ ! -e $T/state-order ]] || { echo 'FAIL: hiding preceded ownership state'; fails=1; }
  if [[ $old == present ]]; then
    cmp -s "$T/old-state" "$STATE" || { echo 'FAIL: failed hide changed old state'; fails=1; }
  else
    [[ ! -e $STATE ]] || { echo 'FAIL: failed hide left ownership'; fails=1; }
  fi
done
reset; rm "$DROPIN"
FAIL_STATE=1 "$T/scripts/enable" >"$T/output" 2>&1
check 'state publish failure exit' "$?" 1
[[ ! -e $T/bar ]] || { echo 'FAIL: hidden before state publish succeeded'; fails=1; }
reset
"$T/scripts/enable" >"$T/output" 2>&1
check 'normal enable exit' "$?" 0
[[ ! -e $T/state-order && ! -e $T/activation && ! -e $T/atomic ]] || { echo 'FAIL: activation, state order or atomic publish'; fails=1; }
[[ $(<"$DROPIN") == $'[Service]\nExecStart=\nExecStart=/usr/bin/fcitx5' ]] || { echo 'FAIL: desired drop-in'; fails=1; }
[[ ! -e $T/mv-failed ]] || { echo 'FAIL: publish did not use mv'; fails=1; }
reset; rm "$DROPIN"
HOSTILE=1 "$T/scripts/enable" >"$T/output" 2>&1
check 'hostile entries exit' "$?" 0
[[ ! -e $T/names ]] || { echo 'FAIL: hostile D-Bus entry or missing --'; cat "$T/names"; fails=1; }

# A failed restart must roll the drop-in back, not leave the unit with an override that does not start.
reset
FAIL_RESTART=1 "$T/scripts/enable" >"$T/output" 2>&1
check 'restart failure exit' "$?" 1
cmp -s "$T/previous" "$DROPIN" || { echo 'FAIL: restart failure lost previous drop-in bytes'; fails=1; }
grep -q 'daemon-reload' "$T/systemctl" || { echo 'FAIL: no reload after rollback'; fails=1; }
# No previous drop-in and the tray never shows up: remove ours again.
reset; rm "$DROPIN"; touch "$T/wait-sni"
NO_SNI=1 "$T/scripts/enable" >"$T/output" 2>&1
check 'no tray exit' "$?" 1
[[ ! -e $DROPIN ]] || { echo 'FAIL: unusable drop-in left behind'; fails=1; }
rm -f "$T/wait-sni"
# A stock ExecStart the rewrite cannot preserve, already covered by our drop-in, is a no-op on rerun.
reset
printf '[Service]\nExecStart=\nExecStart=/usr/bin/fcitx5\n' >"$DROPIN"
CAT_LINE='%h/bin/fcitx5' "$T/scripts/enable" >"$T/output" 2>&1
check 'rerun with unexpandable unit exit' "$?" 0
[[ ! -e $T/systemctl ]] || ! grep -q ' restart ' "$T/systemctl" || { echo 'FAIL: rerun restarted fcitx5'; fails=1; }

# Linked systemd or state directories are never written through.
tree_sum() { (cd "$1" && find . -type f | sort | while read -r f; do cksum "$f"; done); }
for where in systemd state; do
  reset; rm -rf "$HOME/elsewhere"; mkdir -p "$HOME/elsewhere"
  if [[ $where == systemd ]]; then
    mkdir -p "$HOME/elsewhere/dropins"; cp -R "${DROPIN%/*}" "$HOME/elsewhere/dropins/" 2>/dev/null
    rm -rf "$HOME/.config/systemd/user"; ln -s "$HOME/elsewhere/dropins" "$HOME/.config/systemd/user"
  else
    mkdir -p "$HOME/.local"; ln -s "$HOME/elsewhere" "$HOME/.local/state"
  fi
  tree_sum "$HOME/elsewhere" >"$T/elsewhere.before"
  out=$("$T/scripts/enable" 2>&1); rc=$?
  [[ $rc -ne 0 && $out == *symlink* ]] || { echo "FAIL: enable through linked $where: rc=$rc out=$out"; fails=1; }
  check "enable linked $where left target untouched" "$(tree_sum "$HOME/elsewhere")" "$(cat "$T/elsewhere.before")"
done
# Theme failure warns once without failing successful tray enable.
reset; rm "$DROPIN"
THEME_FAIL=1 "$T/scripts/enable" >"$T/theme-out" 2>"$T/theme-err"
check 'theme failure keeps enable successful' "$?" 0
check 'theme failure has one skipped-step warning' "$(grep -c '^Candidate window theme step skipped;' "$T/theme-err")" 1
grep -q 'theme failure reason' "$T/theme-err" || { echo 'FAIL: theme diagnostic lost'; fails=1; }
[[ $(tail -1 "$T/theme-err") == *'see the error above'* ]] || { echo 'FAIL: skipped theme warning lacks guidance'; fails=1; }

# A path swapped after the initial check cannot redirect a later write.
reset; mkdir -p "$T/foreign-user/omarchy-fcitx5.service.d"
echo keep >"$T/foreign-user/omarchy-fcitx5.service.d/zz-input-menu.conf"
before=$(tree_sum "$T/foreign-user")
out=$(SWAP_DROPIN=1 "$T/scripts/enable" 2>&1); check 'drop-in swapped before publish exit' "$?" 1
[[ $out == *symlink* ]] || { echo 'FAIL: late drop-in link lacks reason'; fails=1; }
check 'late drop-in link leaves target' "$(tree_sum "$T/foreign-user")" "$before"
for hidden in no yes; do
  reset; rm -f "$T/state-swapped"; rm -rf "$T/foreign-state"; mkdir -p "$T/foreign-state"; echo keep >"$T/foreign-state/sentinel"
  if [[ $hidden == yes ]]; then echo '{"bar":{"layout":{"right":[{"id":"omarchy.tray","hidden":["Fcitx"]}]}}}' >"$HOME/.config/omarchy/shell.json"; fi
  before=$(tree_sum "$T/foreign-state")
  out=$(SWAP_STATE=1 "$T/scripts/enable" 2>&1); check "state swapped during wait hidden=$hidden exit" "$?" 1
  [[ $out == *symlink* ]] || { echo "FAIL: late state link hidden=$hidden lacks reason"; fails=1; }
  check "late state link hidden=$hidden leaves target" "$(tree_sum "$T/foreign-state")" "$before"
  [[ ! -e $T/bar ]] || { echo 'FAIL: hide happened after late state symlink'; fails=1; }
done

# Relative, chained entry-point symlinks must use the real sibling theme.
reset; rm "$DROPIN"; mkdir -p "$T/links"
ln -s ../scripts/enable "$T/links/first"; ln -s first "$T/links/enable"
printf '#!/bin/bash\necho decoy >"$ENABLE_TEST/decoy-theme"\n' >"$T/links/theme"; chmod +x "$T/links/theme"
rm -f "$T/real-theme"
"$T/links/enable" >"$T/output" 2>&1; check 'linked enable exit' "$?" 0
[[ -e $T/real-theme && ! -e $T/decoy-theme ]] || { echo 'FAIL: linked enable used wrong sibling theme'; fails=1; }

# Existing directories must not become rename containers.
for target in "$DROPIN" "$STATE"; do
  reset; mkdir -p "${target%/*}"; rm -f "$target"; mkdir "$target"; echo keep >"$target/sentinel"
  before=$(tree_sum "$HOME")
  out=$("$T/scripts/enable" 2>&1); check "directory ${target##*/} exit" "$?" 1
  [[ $out == *directory* ]] || { echo "FAIL: directory target has no reason: $target"; fails=1; }
  check "directory ${target##*/} unchanged" "$(tree_sum "$HOME")" "$before"
  [[ ! -e $T/systemctl && ! -e $T/bar ]] || { echo 'FAIL: directory target had side effects'; fails=1; }
done
# A failed rollback operation cannot prevent the remaining cleanup/reload.
reset
UNREADABLE=1 FAIL_ROLLBACK_MV=1 "$T/scripts/enable" >"$T/output" 2>&1
check 'rollback mv failure exit' "$?" 1
check 'reload still follows failed restore mv' "$(tail -1 "$T/systemctl")" '--user daemon-reload'
reset; rm "$DROPIN"; touch "$T/wait-sni"
NO_SNI=1 FAIL_ROLLBACK_RM=1 "$T/scripts/enable" >"$T/output" 2>&1
check 'rollback rm failure exit' "$?" 1
check 'restart still follows failed rollback rm' "$(grep -c ' restart ' "$T/systemctl")" 2
rm -f "$T/wait-sni" "$T/rollback-rm"
reset; rm "$DROPIN"
FAIL_BAR=1 FAIL_ROLLBACK_RM=1 "$T/scripts/enable" >"$T/output" 2>&1
check 'state rollback rm failure exit' "$?" 1
check 'state temp cleanup still runs after failed rm' "$(wc -l <"$T/rollback-rm" | tr -d ' ')" 2
if (( fails )); then echo FAILED; exit 1; fi
echo ok
