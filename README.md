# FlightETA

A small WoW Forever addon. While you're on a flight path it shows how long is left and which stops are between you and your destination.

```
Nethergarde Keep              2:38
[==========-----------]
Lakeshire
> Darkshire                   1:09
Nethergarde Keep              2:38
```

## Install
Copy the `FlightETA` folder into your Forever client's `Interface/AddOns/` folder.

## How it works
- When you pick a destination at a flight master, it reads the route and every stop along the way.
- During the flight it shows a timer, a progress bar, and each stop still ahead with its ETA. Stops you've passed are greyed out.
- The first time you fly a leg, times are estimates (shown with `~`) worked out from distance. It times every leg and full route you fly, so routes you've flown before are exact, and estimates for new legs get better as it learns your flight speed.

## Commands
- `/feta`: stats + help
- `/feta move`: unlock the frame so you can drag it (then `/feta lock`)
- `/feta reset`: forget learned times
