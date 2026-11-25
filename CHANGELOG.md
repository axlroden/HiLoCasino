# Hi-Lo Casino

## 2.3.0

- **Settings panel** (Options → AddOns → Hi-Lo Casino, the gear button in both windows,
  Ctrl-click the minimap icon, or `/hilo options`): stakes, ratio, broadcast channel,
  enter/withdraw keywords, history period and post count, window scale, minimap button,
  lock windows, click sounds, login message, reset window positions.
- `/hilo next` during rolling no longer pushes the round past its last phase.
- A first roll equal to the maximum now counts as the low roll too.
- A Lua error while working out payouts can no longer leave chat stuck in "queue for later" mode.
- Secret chat values are checked before any comparison.
- Code cleanup: about 15% shorter, windows and lists share one set of building blocks;
  the entrant list and buttons only redraw while the window is open.

## 2.2.0

- **Renamed to Hi-Lo Casino** (folder `HiLoCasino`, `/hilo`; `/rc` still works). Another WoW Forever addon already uses the Roll Casino name.

- **History**: every finished round is saved (time, players and rolls, winners, losers, gold won or lost).
- **History window** (`/hilo history`, the History button, or shift-click the minimap icon):
  leaderboard (net gold, rounds, wins/losses, best and worst round) and a round log for
  *This session*, *Today*, *Last 7 days*, *Last 30 days* or *All time*. Hover a round for every roll.
- **Post to chat**: Top N, Bottom N (3/5/10), a period summary, or any single round.
  Also `/hilo top [n] [period]`, `/hilo bottom [n] [period]`, `/hilo summary [period]`.
- **Clean-up**: delete single rounds, clear a whole period, or start a new session (two-click confirm).
- Old running totals are imported once as "Imported totals" (All time only).
- New logo.

## 2.1.0

- New window in the NaowhForever house look; follows NaowhForever's live theme and fonts when installed.
- Entrant list sorted by roll with winner/loser markers.

## 2.0.1

- WoW Forever support (interface 16001, `C_ChatInfo.SendChatMessage`).
- Rolls from players whose names contain spaces are now recognised.
- Secret chat values (chat lockdown) are skipped instead of erroring.
- Say/custom-channel payouts wait behind an **Announce Results** click instead of being blocked.
