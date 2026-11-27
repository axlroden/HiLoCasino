# Hi-Lo Casino

## 2.5.0

- **Play with other Hi-Lo Casino users:** players in your group, guild or custom channel who have
  the addon see the round you run in their window and can join it with the **Enter (me)** and
  **Roll (me)** buttons (Roll works once per round).
- **One round at a time:** while someone runs a round, others who would reach the same players
  can't start one ("Alpha is hosting"). If two start at once, the earlier start keeps it and the
  other is cancelled with a note in chat. A host that disconnects stops blocking after a minute.
- **Shared stats:** finished rounds go to your group and guild, and you catch up on missed rounds
  when you log in or join a group. Everyone's History and leaderboards count the same games.
  Rounds are only taken from the player who hosted them. Hover a round to see the host. Rounds
  from others that you delete stay deleted. You can turn sharing off in the settings.

## 2.4.0

- **Entries typed in combat:** Forever hides chat from addons in combat, so a `1` typed then
  can't be read, not even afterwards. Hi-Lo Casino now notices those hidden lines and, when
  combat ends, posts "Chat was hidden during combat - type 1 again to join!" (only a note to
  you when the channel needs a click to post). Rolls hidden in combat get a note to you listing
  who still has to roll; nobody is asked to re-roll.
- **The round waits while you're in combat:** the next-phase button, Enter and Roll are greyed out
  and the window says "paused: combat", so no round starts and no one is told to roll while chat
  can't be read. You get a note when combat starts and ends.
- **Type in a missed roll:** click a player who still has to roll in the list and type the roll
  you see in chat (Enter to take it, Esc to cancel), or use `/hilo roll <name> <roll>`.
  Typed-in rolls show a `*`.
- `/hilo top 5 week` (and `bottom` / `summary`) now use the period you give; before, only the
  first word after the command was read.
- **Session and All-time buttons:** the main window posts Session Top / Bottom N and All-time
  Top / Bottom N directly. History's buttons still post the period picked there.
- A player whose name was saved with a hyphen in some rounds and a space in others is counted
  as one player.
- **History counts all rounds by default:** the period now starts on *All time*, so Top / Bottom,
  the leaderboard and the summary add up every round. Pick another period in History if you want.
- *This session* survives `/reload` (it only restarts on a fresh login or with New session).
- **Top / Bottom lists fixed:** Top only lists players who are up and Bottom only players who are
  down. Before, both listed everyone, so a winner could show up on the Bottom list.
- **Tied rolls counted right:** "A, B owes C 5g each" now gives C 10g (and "A owes B, C 5g each"
  takes 10g from A) in the history, leaderboards and summary. Rounds already saved are
  recalculated too.
- The summary only names an Unluckiest player when someone is actually down.

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
