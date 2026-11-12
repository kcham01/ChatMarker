# BookPins

A small WoW Forever addon that pins all 40 arcane books on the world map and plans a short route through them.

## Install
Copy the `BookPins` folder into `World of Warcraft/_forever_/Interface/AddOns/` (or whichever `_xxx_` folder your Forever client uses). If it shows as out of date, tick **Load out of date AddOns** on the character-select AddOns screen.

## What it does
- Book icon pins on zone, continent and world maps. Hover for title, type and coords; **left-click** sets a waypoint, **right-click** toggles collected.
- Plans a route per continent from where you stand, using a nearest-neighbour start plus 2-opt cleanup (the same kind of TSP heuristic the *Routes* addon uses). Pins are numbered and joined with a gold line.
- `/books next` sets the game's own waypoint (and a TomTom arrow if TomTom is installed). When you get within 10 yards it marks the book collected and moves on to the next one (`/books auto` turns this off).
- Progress is saved per account.

## Commands
| | |
|---|---|
| `/books` | help + how many are left |
| `/books next` | waypoint to the next stop |
| `/books route` | re-plan from your current position |
| `/books list` | print the route |
| `/books done` | mark current target collected |
| `/books auto` | toggle auto-collect on arrival |
| `/books lines` / `collected` / `toggle` | route lines / show collected pins / hide everything |
| `/books clear` / `reset` | clear waypoint / un-collect everything |

Distances are straight-line, so the route can't account for mountains, flight paths or boats. Kalimdor and the Eastern Kingdoms are planned as separate legs, and your current continent comes first.
