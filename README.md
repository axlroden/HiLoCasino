<p align="center"><img src="media/logo.png" width="128" alt="Hi-Lo Casino logo"></p>

# Hi-Lo Casino

Host Hi/Lo gold roll games in **WoW Forever**. Hi-Lo Casino announces the round, collects
entries from chat, reads everyone's `/roll`, works out who owes whom, and keeps a full
history with leaderboards you can post to chat.

## How a round works

1. Pick the stakes, the roll:gold ratio and where to broadcast (Say, Party, Raid, Guild or a custom channel).
2. **Start Round**: players type `1` to enter (`-1` to withdraw).
3. **Announce Last Call**, then **Begin Rolling**: everyone does `/roll 1-<stakes × ratio>`.
4. When the last roll lands, the lowest roller owes the highest the difference, posted to chat.

With Say (outside instances) or a custom channel the game only lets addons post after a click,
so the payout waits behind an **Announce Results** button.

## History and leaderboards

Every finished round is stored. Open **History** to see, for *This session*, *Today*,
*Last 7 days*, *Last 30 days* or *All time*:

- a leaderboard: net gold, rounds, wins/losses, best and worst round
- a round log: hover a round for every roll, **Post** it again, or delete it

Post the **Top N**, **Bottom N** or a **Summary** to chat with one click.

## Settings

Everything can be set without typing commands: **Options → AddOns → Hi-Lo Casino**, the gear
button in either window, Ctrl-click on the minimap icon, or `/hilo options`.

- **Round**: stakes, roll:gold ratio, where to broadcast, custom channel name
- **Chat keywords**: what players type to enter and withdraw
- **History**: default period and how many players Top/Bottom posts list
- **Interface**: window scale, minimap button, lock window positions, click sounds,
  login message, reset window positions

## Commands

Get it on [CurseForge](https://www.curseforge.com/wow/addons/hi-lo-casino) (project 1831355). Named *Roll Casino* before 2.2.0.

| Command | |
|---|---|
| `/hilo` | Toggle the window (`/rc` works too) |
| `/hilo options` | Open the settings |
| `/hilo history` | Leaderboard and round log |
| `/hilo top [n] [period]` | Post the top *n* winners (period: `session`, `today`, `week`, `month`, `all`) |
| `/hilo bottom [n] [period]` | Post the *n* biggest losers |
| `/hilo summary [period]` | Post a summary of the period |
| `/hilo newsession` | Start a new "This session" |
| `/hilo next` / `/hilo reset` | Advance / reset the current round |
| `/hilo gold <n>` / `/hilo ratio <n>` | Stakes in gold / roll:gold ratio |
| `/hilo channel <name>` | Custom chat channel |
| `/hilo minimap` | Toggle the minimap button |

## Looks

The window uses the NaowhForever house style and follows
its live theme and fonts when NaowhForever is installed; otherwise it uses the Midnight palette.

## License

MIT. See [LICENSE](LICENSE).
