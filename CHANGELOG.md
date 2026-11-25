# Roll Casino

## 2.2.0

- **History**: every finished round is saved (time, players and rolls, winners, losers, gold won or lost).
- **History window** (`/rc history`, the History button, or shift-click the minimap icon):
  leaderboard (net gold, rounds, wins/losses, best and worst round) and a round log for
  *This session*, *Today*, *Last 7 days*, *Last 30 days* or *All time*. Hover a round for every roll.
- **Post to chat**: Top N, Bottom N (3/5/10), a period summary, or any single round.
  Also `/rc top [n] [period]`, `/rc bottom [n] [period]`, `/rc summary [period]`.
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
