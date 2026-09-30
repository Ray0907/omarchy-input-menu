#!/bin/bash
# Sandbox scripts/disable's theme cleanup before/after a tray restart.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" DISABLE_TEST="$T"
REAL_RMDIR=$(command -v rmdir); export REAL_RMDIR
mkdir -p "$T/bin" "$T/scripts"
cp "$HERE/scripts/disable" "$T/scripts/disable"
cp "$HERE/scripts/theme" "$T/scripts/theme.real"
cat >"$T/scripts/theme" <<'STUB'
#!/bin/bash
echo "theme $*" >>"$DISABLE_TEST/calls"
exec "$DISABLE_TEST/scripts/theme.real" "$@"
STUB
cat >"$T/bin/busctl" <<'STUB'
#!/bin/bash
echo "busctl $*" >>"$DISABLE_TEST/calls"
[[ " $* " == *' --auto-start=no '* ]] || { echo bad >>"$DISABLE_TEST/activation"; exit 1; }
if [[ " $* " == *' State '* && -e $DISABLE_TEST/pending ]]; then
  n=$(<"$DISABLE_TEST/pending")
  if (( n > 0 )); then echo "$((n - 1))" >"$DISABLE_TEST/pending"; exit 1; fi
  rm "$DISABLE_TEST/pending"; touch "$DISABLE_TEST/running"
fi
if [[ " $* " == *' Exit '* ]]; then rm -f "$DISABLE_TEST/running"; exit 0; fi
[[ -e $DISABLE_TEST/running ]] || exit 1
if [[ " $* " == *' GetConfig '* ]]; then
  read -r t d <"$DISABLE_TEST/classicui"
  jq -nc --arg t "$t" --arg d "$d" '{data:[{data:{Theme:{data:$t},DarkTheme:{data:$d}}}]}'
elif [[ " $* " == *' SetConfig '* ]]; then
  a=("$@"); t=; d=
  for i in "${!a[@]}"; do [[ ${a[i]} == Theme ]] && t=${a[i+2]}; [[ ${a[i]} == DarkTheme ]] && d=${a[i+2]}; done
  echo "$t $d" >"$DISABLE_TEST/classicui"
  printf 'Theme=%s\nDarkTheme=%s\n' "$t" "$d" >"$HOME/.config/fcitx5/conf/classicui.conf"
fi
exit 0
STUB
cat >"$T/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$DISABLE_TEST/calls"
if [[ " $* " == *' restart '* && -z ${FAIL_START:-} ]]; then echo 3 >"$DISABLE_TEST/pending"; fi
STUB
cat >"$T/bin/sleep" <<'STUB'
#!/bin/bash
echo "sleep $*" >>"$DISABLE_TEST/calls"
STUB
cat >"$T/bin/rmdir" <<'STUB'
#!/bin/bash
for path; do :; done
exec "$REAL_RMDIR" "$path"
STUB
chmod +x "$T/bin/"* "$T/scripts/"*
export PATH="$T/bin:$PATH"
fails=0
check() { if [[ $2 != "$3" ]]; then echo "FAIL: $1: got [$2] want [$3]"; fails=1; fi; }
D="$HOME/.local/share/fcitx5/themes/omarchy-input-menu"
HOOK="$HOME/.config/omarchy/hooks/theme-set.d/input-menu"
STATE="$HOME/.local/state/input-menu/theme.json"
TPL="$HOME/.config/omarchy/themed/input-menu-fcitx5.conf.tpl"
reset() {
  rm -rf "$HOME"; rm -f "$T/running" "$T/pending" "$T/calls"
  mkdir -p "$HOME/.config/systemd/user/omarchy-fcitx5.service.d" "$HOME/.config/fcitx5/conf" "${HOOK%/*}" "${TPL%/*}" "${STATE%/*}" "$D"
  echo '[Service]' >"$HOME/.config/systemd/user/omarchy-fcitx5.service.d/zz-input-menu.conf"
  printf 'Theme=omarchy-input-menu\nDarkTheme=omarchy-input-menu\n' >"$HOME/.config/fcitx5/conf/classicui.conf"
  echo 'omarchy-input-menu omarchy-input-menu' >"$T/classicui"
  echo '{"previous":{"Theme":"default","DarkTheme":"default-dark"}}' >"$STATE"
  echo marker >"$HOOK"; echo marker >"$TPL"; echo marker >"$D/theme.conf"
}
cleaned() {
  [[ ! -e $D && ! -e $HOOK && ! -e $TPL && ! -e $STATE ]] || { echo "FAIL: $1 left theme artifacts"; fails=1; }
  check "$1 restored stock" "$(<"$T/classicui")" 'default default-dark'
}

reset; touch "$T/running"
bash "$T/scripts/disable" >"$T/output" 2>&1
check 'up first exit' "$?" 0
check 'up first calls theme once' "$(grep -c '^theme disable$' "$T/calls")" 1
cleaned 'up first'
grep -q 'cleanup deferred' "$T/output" && { echo 'FAIL: successful cleanup reported deferred'; fails=1; }

reset
bash "$T/scripts/disable" >"$T/output" 2>&1
check 'up after restart exit' "$?" 0
check 'up after restart retries theme' "$(grep -c '^theme disable$' "$T/calls")" 2
check 'restart wait sleeps instead of spinning' "$(grep -c '^sleep 0.5$' "$T/calls")" 3
cleaned 'up after restart'
grep -q 'cleanup deferred' "$T/output" && { echo 'FAIL: successful retry reported deferred'; fails=1; }

reset; export FAIL_START=1
before=$(cksum "$STATE" "$HOOK" "$TPL" "$D/theme.conf")
bash "$T/scripts/disable" >"$T/output" 2>&1
check 'always down exit' "$?" 0
check 'always down wait bounded to ten seconds' "$(grep -c '^sleep 0.5$' "$T/calls")" 20
check 'always down keeps selection' "$(<"$T/classicui")" 'omarchy-input-menu omarchy-input-menu'
check 'always down keeps artifacts' "$(cksum "$STATE" "$HOOK" "$TPL" "$D/theme.conf")" "$before"
check 'one deferred cleanup message' "$(grep -c 'Candidate-window theme cleanup deferred' "$T/output")" 1
grep -qF "$T/scripts/theme disable" "$T/output" || { echo 'FAIL: deferred message lacks exact retry command'; fails=1; }
[[ ! -e $T/activation ]] || { echo 'FAIL: D-Bus activation allowed'; fails=1; }
if (( fails )); then echo FAILED; exit 1; fi
echo ok
