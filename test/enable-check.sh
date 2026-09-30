#!/bin/bash
# Sandbox enable's failed rebuilds and tray ownership transaction.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" ENABLE_TEST="$T"
mkdir -p "$T/bin" "$T/scripts"
cp "$HERE/scripts/enable" "$T/scripts/enable"
printf '#!/bin/bash\nexit 0\n' >"$T/scripts/theme"
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
    [[ ${UNREADABLE:-} != 1 ]] || exit 1
    printf '{ path=/usr/bin/fcitx5 ; argv[]=%s ; ignore_errors=%s ; }\n' "${FCITX_ARGV:-/usr/bin/fcitx5 --disable notificationitem}" "${IGNORE_ERRORS:-no}"
    ;;
esac
STUB
REAL_MV=$(command -v mv); export REAL_MV
cat >"$T/bin/mv" <<'STUB'
#!/bin/bash
a=("$@"); n=${#a[@]}; src=${a[n-2]}; dest=${a[n-1]}
if [[ $dest == */zz-input-menu.conf ]]; then
  [[ ${src%/*} == "${dest%/*}" ]] || echo bad >"$ENABLE_TEST/atomic"
  if [[ ${FAIL_PUBLISH:-} == 1 && ! -e $ENABLE_TEST/mv-failed ]]; then touch "$ENABLE_TEST/mv-failed"; exit 1; fi
fi
if [[ $dest == */input-menu-enable.json && ${FAIL_STATE:-} == 1 ]]; then exit 1; fi
exec "$REAL_MV" "$@"
STUB
printf '#!/bin/bash\nexit 0\n' >"$T/bin/sleep"
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
if (( fails )); then echo FAILED; exit 1; fi
echo ok
