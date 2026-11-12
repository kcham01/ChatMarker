# FlightETA

A WoW Forever addon for flight paths. While you fly it shows how long is left, every stop the game can actually land you at, and where the **stop button** will put you down, including how long you have left to press it.

```
Nethergarde Keep              2:57
[==========-----------]
Lakeshire  (passed)
> Darkshire                   1:29
Nethergarde Keep              2:57
Stop button: Darkshire in 1:29 (press within 1:23)
```

## Install
Copy the `FlightETA` folder into your Forever client's `Interface/AddOns/` folder.

## How flight paths work (and what FlightETA does about it)
- **Your route depends on the flight points you've unlocked.** Unlocking one in between can change the route and its time. FlightETA saves times per route, keyed by every stop's flight point ID, so a changed route gets its own time instead of mixing with the old one.
- **The stop button lands you at the next unlocked flight point on the route.** Points you haven't unlocked are flown past, and a route straight to the destination shows as **Nonstop**. Press it and the timer switches to that stop, with the rest of the route marked skipped.
- **Pressing stop too late lands you at the next stop instead.** The taxi takes a fly-past path just before each stop. When you press too late, FlightETA notices you flew past and learns that stop's deadline. After that, it shows how long you have left to press, and it switches to the next stop once that time runs out.
- **Frequent Flier** (Legacy perk, 20% faster flights) is detected per character, using the same Legacy talent check as InFlight. All times are stored without the boost, so every character shares them. Use `/feta ff on|off|auto` if the detection is wrong.
- **Summons, battleground or dungeon finder teleports** during a flight: the flight isn't timed, so it can't spoil your times. The timer survives `/reload`. After a relog, the game resumes the flight and lands you at the next stop, which the timer follows.

## Where the times come from
1. **Your own flights:** exact, shown without `~`. Flying past a stop and landing at it are timed separately, because landing adds the descent.
2. **Classic Era reference times** from [InFlight](https://github.com/LudiusMaximus/InFlight) (MIT, see `FlightETA/LICENSE-InFlight.txt`), used per leg between your actual stops. They were recorded on Classic Era, so they're shown with `~` until you fly the route.
3. **Distance**, for legs with no data: worked out from the flight speed it has learned.

## Flight log (for building a database)
Logging is on by default. Every flight saves the route and stops, when each stop was passed, stop-button presses (and whether they were too late), where you landed vs where it expected, the Frequent Flier status and a position trace every 2 seconds. It also saves every flight master you see on a flight map, with its exact position for the ones you've stood at.

The game writes it to `WTF/Account/<ACCOUNT>/SavedVariables/FlightETA.lua` when you log out or `/reload`. Turn it into JSON/CSV with:

```
python3 tools/export_flights.py "<path to>/FlightETA.lua" out
```

That gives `flights.json` (everything), `flights.csv`, `legs.csv` (each pass/landing with its time) and `flight_masters.csv`.

## Commands
- `/feta`: stats + help
- `/feta move` / `/feta lock`: position the frame
- `/feta ff on | off | auto`: Frequent Flier override for this character
- `/feta log` / `/feta log clear`: turn logging on/off, or delete saved flights
- `/feta reset`: forget learned times and deadlines
