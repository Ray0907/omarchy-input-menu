# Input Menu

A macOS-style input source menu for the Omarchy bar, for anyone typing with fcitx5.

- The boxed badge shows the current input method **and mode**: `A`, `ㄅ`, `あ`, `ア`.
- Click it for every input method and engine mode, with a check on the current one. Arrow keys, Enter and Esc work; right-click toggles like `Ctrl+Space`.
- It updates on window focus changes and fcitx5 events. Nothing polls: when idle it starts no processes.
- Names follow the system language: English, 繁體中文, 日本語. Zhuyin, Japanese (Mozc) and ABC get macOS-style names; any other engine shows the name fcitx5 gives it.
- When fcitx5 isn't running, or only one input method is set up, the badge dims and the menu says what to do.

## Requirements

- Omarchy 4 with fcitx5 started by the `omarchy-fcitx5` user service.
- The input methods you want, installed separately (for example `fcitx5-chewing`, `fcitx5-mozc`). Input Menu doesn't install engines yet; **Add Input Method…** opens fcitx5's own settings.

## Install

```sh
omarchy plugin add https://github.com/Ray0907/omarchy-input-menu.git --enable
```

Omarchy starts fcitx5 without its tray interface, which is where the current mode comes from. On first use the menu offers **Enable Input Menu…**; it turns the interface on, restarts fcitx5 once, and hides fcitx5's own tray icon, since Input Menu shows the same thing. No sudo needed.

**Save your work first.** Already-open applications may need to be refocused or reopened before typing works again after the restart.

## Remove

```sh
~/.config/omarchy/plugins/io.github.ray0907.input-menu/scripts/disable
omarchy plugin remove io.github.ray0907.input-menu
```

`disable` removes the override and restarts fcitx5 again, so the same advice applies. It unhides the tray icon only if Input Menu was the one that hid it.

## Limits

- An engine's modes appear in the menu after it has been used once on this machine; they are then cached.
- fcitx5-chewing doesn't publish full/half-width state.
- Mozc Romaji and the ABC keyboard share the badge `A`; their names in the menu differ.
- The candidate window's position can't be configured in fcitx5's classic UI.

## End-to-end test

`./verify.sh` runs on an Omarchy machine against the real fcitx5. It needs an unlocked session, **no application windows**, and a single fcitx5 owned by the user service; it refuses otherwise, because restarting fcitx5 invalidates open windows' input contexts.

It types into a throwaway terminal, restarts fcitx5, and temporarily changes the input group, shell locale, theme and bar layout. It restores all of that on exit, including on errors and signals, and leaves a log and screenshots in `verify-out/` (the screenshots are for looking at, not automated checks).

The result is `ALL PASS`, `PASS WITH SKIPS: <steps>` or `SOME FAILED`. A skipped step is never counted as a pass: if the compositor doesn't deliver a synthetic mouse click the run says `PASS WITH SKIPS: mouse-click`, and on more than one monitor the idle check is skipped.

### If a run is interrupted

The script records what it is about to change in `~/.local/state/input-menu-verify/` before changing anything. A new run refuses to start while an interrupted one is unresolved.

- `./verify.sh --status` shows whether a run is in progress, interrupted or clean.
- `./verify.sh --recover` only **previews**: it lists saved and current values and marks unchanged ones as skipped.
- `./verify.sh --recover --yes` applies them. Look at every difference first; anything you changed by hand since the interruption is overwritten.
- If fcitx5 has to restart while other applications are open, recovery refuses unless you also pass `--yes-restart-fcitx5`.

If `--status` says the recovery data is **broken**, stop and restore by hand:

1. Look at `restore.json` and `backups/` in `~/.local/state/input-menu-verify/`; check ownership and compare `sha256sum` with a copy you trust.
2. Restore `backups/shell.json` to `~/.config/omarchy/shell.json`.
3. Restore `backups/zz-input-menu.conf` to `~/.config/systemd/user/omarchy-fcitx5.service.d/`, or delete that file if the original was absent.
4. Run `systemctl --user daemon-reload` and `omarchy-restart-shell`.
5. Check the input group, current input method, locale, theme and tray, then delete the `in-progress` marker in that directory.

`VERIFY_FAIL_AFTER=<step> ./verify.sh` makes a run fail at a chosen step, to exercise the restore path.
