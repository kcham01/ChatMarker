#!/usr/bin/env python3
"""Export FlightETA's flight log to JSON and CSV for a database.

Usage:
    python3 export_flights.py "<WoW>/_forever_/WTF/Account/<ACCOUNT>/SavedVariables/FlightETA.lua" [out_dir]

Writes flights.json (everything, including position traces), flights.csv
(one row per flight), legs.csv (one row per stop passed or landed at) and
flight_masters.csv (every flight master seen on a flight map).
"""
import csv, json, os, re, sys

TOKEN = re.compile(r'''\s*(?:(--\[\[.*?\]\]|--[^\n]*)|("(?:\\.|[^"\\])*")|(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)|(true|false|nil)|([A-Za-z_][A-Za-z0-9_]*)|(\[|\]|\{|\}|=|,|;))''', re.S)

def tokens(text):
    pos = 0
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            if text[pos:].strip() == "":
                return
            raise ValueError("can't parse near: " + text[pos:pos + 40])
        pos = m.end()
        comment, string, number, word, name, sym = m.groups()
        if comment:
            continue
        if string is not None:
            yield ("val", json.loads(string.replace("\\\n", "\\n")) if "\\" not in string else bytes(string[1:-1], "utf-8").decode("unicode_escape"))
        elif number is not None:
            yield ("val", float(number) if any(c in number for c in ".eE") else int(number))
        elif word is not None:
            yield ("val", {"true": True, "false": False, "nil": None}[word])
        elif name is not None:
            yield ("name", name)
        elif sym:
            yield ("sym", sym)

class Parser:
    def __init__(self, text):
        self.t = list(tokens(text)); self.i = 0
    def peek(self, k=0): return self.t[self.i + k] if self.i + k < len(self.t) else (None, None)
    def take(self): tok = self.t[self.i]; self.i += 1; return tok
    def value(self):
        kind, v = self.take()
        if kind == "val": return v
        if (kind, v) == ("sym", "{"): return self.table()
        raise ValueError(f"unexpected {kind} {v}")
    def table(self):
        arr, obj, n = [], {}, 1
        while self.peek() != ("sym", "}"):
            if self.peek() == ("sym", "["):
                self.take(); key = self.value(); self.take(); self.take()  # ] =
                obj[key] = self.value()
            elif self.peek()[0] == "name" and self.peek(1) == ("sym", "="):
                key = self.take()[1]; self.take(); obj[key] = self.value()
            else:
                obj[n] = self.value(); n += 1
            if self.peek() in (("sym", ","), ("sym", ";")): self.take()
        self.take()
        if obj and all(isinstance(k, int) for k in obj) and sorted(obj) == list(range(1, len(obj) + 1)):
            return [obj[k] for k in range(1, len(obj) + 1)]
        return obj
    def assignments(self):
        out = {}
        while self.i < len(self.t):
            name = self.take()[1]; self.take(); out[name] = self.value()
        return out

def as_list(x):
    if isinstance(x, list): return x
    if isinstance(x, dict): return [x[k] for k in sorted(x)]
    return []

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    out = sys.argv[2] if len(sys.argv) > 2 else "."
    os.makedirs(out, exist_ok=True)
    data = Parser(open(sys.argv[1], encoding="utf-8").read()).assignments()
    log = data.get("FlightETALog") or {}
    flights = as_list(log.get("flights"))
    nodes = log.get("nodes") or {}

    with open(os.path.join(out, "flights.json"), "w", encoding="utf-8") as f:
        json.dump({"flights": flights, "flight_masters": nodes}, f, indent=1, ensure_ascii=False)

    with open(os.path.join(out, "flights.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["n", "date", "char", "realm", "faction", "level", "frequent_flier", "route", "from", "to", "hops",
                    "seconds", "expected", "ended", "stop_pressed_at", "stop_expected", "stop_missed",
                    "landed_nearest", "landed_yards"])
        for n, fl in enumerate(flights, 1):
            sb, ld = fl.get("stopButton") or {}, fl.get("landed") or {}
            w.writerow([n, fl.get("date"), fl.get("char"), fl.get("realm"), fl.get("faction"), fl.get("level"),
                        fl.get("frequentFlier"), fl.get("route"), (fl.get("from") or {}).get("name"),
                        (fl.get("to") or {}).get("name"), fl.get("hops"), fl.get("total"), fl.get("expected"),
                        fl.get("ended"), sb.get("at"), sb.get("expected"), sb.get("missed"),
                        ld.get("nearestName"), ld.get("nearestYards")])

    with open(os.path.join(out, "legs.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["n", "faction", "frequent_flier", "from_id", "from", "to_id", "to", "seconds", "kind", "estimated"])
        for n, fl in enumerate(flights, 1):
            prev, prev_t = fl.get("from") or {}, 0.0
            for st in as_list(fl.get("stops")):
                if st.get("passedAt") is not None:
                    w.writerow([n, fl.get("faction"), fl.get("frequentFlier"), prev.get("nodeID"), prev.get("name"),
                                st.get("nodeID"), st.get("name"), round(st["passedAt"] - prev_t, 1), "pass", st.get("estimated")])
                    prev, prev_t = st, st["passedAt"]
                else:
                    if fl.get("ended") == "landed" and fl.get("total") is not None:
                        w.writerow([n, fl.get("faction"), fl.get("frequentFlier"), prev.get("nodeID"), prev.get("name"),
                                    st.get("nodeID"), st.get("name"), round(fl["total"] - prev_t, 1), "land", None])
                    break

    with open(os.path.join(out, "flight_masters.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["key", "nodeID", "name", "faction", "mapID", "x", "y", "continent", "world_x", "world_y", "exact"])
        for key, nd in sorted(nodes.items(), key=lambda kv: str(kv[0])):
            w.writerow([key, nd.get("nodeID"), nd.get("name"), nd.get("faction"), nd.get("mapID"), nd.get("x"), nd.get("y"),
                        nd.get("cont"), nd.get("wx"), nd.get("wy"), nd.get("exact")])

    print(f"{len(flights)} flights, {len(nodes)} flight masters -> {os.path.abspath(out)}")

if __name__ == "__main__":
    main()
