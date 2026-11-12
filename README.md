# FlightETA

A small WoW Forever addon. While you're on a flight path it shows how long is left and which stops are between you and your destination.

```
Nethergarde Keep              2:38
[==========-----------]
Lakeshire  (passed)
> Darkshire                   1:09
Nethergarde Keep              2:38
Stop button lands you at Darkshire in 1:09
```

## Install
Copy the `FlightETA` folder into your Forever client's `Interface/AddOns/` folder.

## How it works
- When you pick a destination at a flight master, it reads the route's stops: the flight points the game will actually set you down at if you press the stop button. A route that just flies over other flight points without stopping shows as **Nonstop**.
- It shows where the stop button would land you right now and how long that takes. Press it and the timer switches to that stop, with the rest of the route marked skipped.
- During the flight it shows a timer, a progress bar, and each stop still ahead with its ETA. Stops you've passed are greyed out.
- The first time you fly a leg, times are estimates (shown with `~`) worked out from distance. It times every leg and full route you fly, so routes you've flown before are exact, and estimates for new legs get better as it learns your flight speed.

## Commands
- `/feta`: stats + help
- `/feta move`: unlock the frame so you can drag it (then `/feta lock`)
- `/feta reset`: forget learned times
