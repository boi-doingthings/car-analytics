# Data dictionary

Everything lives under `data/` (excluded from git) except `web/data.json`. Data flows one way:

```
Bluelink API ──collect.py──▶ data/raw/*.json ──build_db.py──▶ data/bluelink.db ─┐
                              (source of truth)               (rebuildable)     ├─insights.py──▶ web/data.json, performance.json, fuel.json
Your fuel log ─────────────────────────────────────────── Sheet 1-Car Fuel.csv ─┘   (fuel.py, performance.py)      (rebuildable)
```

Only `data/raw/` is irreplaceable: Hyundai deletes GPS routes after ~3 months. Delete `bluelink.db` or
`web/data.json` and they're rebuilt from raw on the next sync.

All times are India local time (IST). `<vid>` is the vehicle's Bluelink ID (`e7e36680-…`); there is one folder per car.

## Files at a glance

| Path | What it is | Written by | Keep? |
|---|---|---|---|
| `data/raw/days/<vid>/<yyyymmdd>.json` | One day's trip summary and trip list, one file per calendar day (days without driving included) | `collect.py` | **Irreplaceable** |
| `data/raw/trips/<vid>/<tripId>.json` | One trip's stats plus GPS breadcrumbs | `collect.py` | **Irreplaceable** |
| `data/raw/snapshots/<vid>/<yyyymmddTHHMMSS>/` | Car status at one sync: `vehicles`, `status_latest`, `location_park`, `maintenance_alert` | `collect.py` | **Irreplaceable** (fuel/odometer history) |
| `data/bluelink.db` | SQLite tables built from raw | `build_db.py` | Rebuildable |
| `web/data.json` | Everything the dashboard shows, precomputed | `insights.py` | Rebuildable |
| `Sheet 1-Car Fuel.csv` (project root) | Your fuel purchases: date, amount, station, litres, odometer, rate, brand. Hand-maintained; `fuel.py` also accepts `data/fuel_log.csv` | You | **Irreplaceable** (keep adding rows) |
| `web/performance.json`, `web/fuel.json` | Inputs for the Performance and Fuel pages | `insights.py` | Rebuildable |
| `data/last_sync.json` | `{"last_sync": "<ISO time>"}` of the last successful sync; drives the 12-hour auto-sync | `serve.py` | Small state file |
| `data/collect.log` | Append-only log of every sync (collector stats, errors) | `serve.py`, `run.sh` | Log |

Rules in `collect.py` that protect the archive: day files are only re-fetched within the last 7 days;
trip files are never overwritten once older than 7 days (a later fetch could only have a purged route).

## Raw API files

Every response is saved verbatim: `{"retCode": "S", "resCode": "0000", "resMsg": {…}, "msgId": "…"}`.
`retCode` `S` means success. The fields below are inside `resMsg`.

### `days/<vid>/<yyyymmdd>.json` (endpoint `POST /tripinfo`, `tripPeriodType: 1`)

`dayTripList` is empty on days without driving; otherwise it holds one entry:

| Field | Unit | Meaning |
|---|---|---|
| `tripDay` | `yyyymmdd` | The day |
| `dayTripCnt` | count | Trips that day |
| `tripDist` | km (whole) | Distance that day |
| `tripDrvTime` | minutes | Time moving. **Excludes idling** |
| `tripIdleTime` | minutes | Time stationary with the engine on |
| `tripAvgSpeed` | km/h | Average while moving |
| `tripMaxSpeed` | km/h | Top speed that day |
| `startLat/Lon`, `endLat/Lon` | degrees | First start / last end. Replaced by the current parking spot once the route is purged |
| `tripList[]` | | One entry per trip: `tripStartTime`, `tripEndTime` (`yyyymmddHHMMSS`), `tripStartCoord`, `tripEndCoord` (`{lat, lon}`), `serviceTID` (trip ID, equal to the start time) |

### `trips/<vid>/<tripId>.json` (endpoint `POST /tripinfo/detail`)

`tripInfo` holds one trip:

| Field | Unit | Meaning |
|---|---|---|
| `tripStartTime`, `tripEndTime` | `yyyymmddHHMMSS` | Trip start and end; the file name is the start time |
| `tripDist` | km (whole) | Distance |
| `tripDrvTime`, `tripIdleTime` | minutes | Moving / idling time; together they make up the trip |
| `tripAvgSpeed`, `tripMaxSpeed` | km/h | Average while moving, top speed |
| `tripHardBreakingTime` | count | Harsh-braking events (Hyundai's spelling) |
| `tripRapidAccelationTime` | count | Rapid-acceleration events |
| `tripExcessiveSpeedTime` | count | Speeding events |
| `tripStartCoord`, `tripEndCoord` | degrees | Start / end. Unreliable once the route is purged |
| `tripList[]` | | GPS breadcrumbs: `{tripTime: "HHMMSS", lat, lon}`, ~6 per minute sharing one minute-level timestamp. **Hyundai purges these after ~3 months**, leaving 0–1 points |
| `dayTripCnt` | | Always 1 here; ignore |

### `snapshots/<vid>/<ts>/` (one folder per sync; folder name is when it was taken)

**`vehicles.json`** (`GET /vehicles`): `vehicles[]` with `vehicleId`, `nickname`, `vehicleName` (`i20`),
`type` (`GN` = petrol), `year`, `regDate` (registration, drives the time-based service dates), `vin`,
`detailInfo` (colour and model codes), `ccuCCS2ProtocolSupport` (0 = older telematics protocol).

**`status_latest.json`** (`GET /status/latest`; the server's cached status, never wakes the car):

| Field | Meaning |
|---|---|
| `time` | When the car last reported (`yyyymmddHHMMSS`) |
| `fuelLevel` | Fuel tank, % (tank is 37 L) |
| `dte.value` | Range left ("distance to empty"), km |
| `lowFuelLight` | Low-fuel warning on |
| `doorLock`, `doorOpen.*`, `trunkOpen`, `hoodOpen`, `sunroofOpen` | Lock and opening states |
| `engine`, `acc`, `ign3`, `airCtrlOn`, `defrost` | Engine, accessory power, climate states |
| `battery.batState` | 12 V battery state code (1 seen = normal) |
| `tirePressureLamp.*` | Tyre-pressure warning per wheel (0 = off) |
| `washerFluidStatus`, `breakOilStatus`, `engineOilStatus`, `smartKeyBatteryWarning` | Warning lamps (false = fine) |
| `lampWireStatus.*` | Bulb-failure flags |
| `airTemp`, `seatHeaterVentState`, `steerWheelHeat`, `airCleaning` | Cabin settings (mostly unused on this car) |

**`location_park.json`** (`GET /location/park`): `coord.lat/lon` where the car is parked, `time`, `speed`.

**`maintenance_alert.json`** (`GET /setting/alert/maintenance`): `odometer` (km) and `mainList[]` of
service items: `itemId` (e.g. `Engine oil`), `items.distValue` (interval, km), `items.termValue`
(interval, months; 0 = none).

## `data/bluelink.db` (SQLite)

**`days`**: one row per day with driving. Columns: `vehicle_id`, `day` (`YYYY-MM-DD`), `trip_count`,
`distance_km`, `drive_min`, `idle_min`, `avg_kmh`, `max_kmh`.

**`trips`**: one row per trip.

| Column | Meaning |
|---|---|
| `vehicle_id`, `trip_id` | Key; `trip_id` = start time `yyyymmddHHMMSS` |
| `day`, `start_ts`, `end_ts` | `YYYY-MM-DD`, `YYYY-MM-DD HH:MM:SS` |
| `distance_km`, `drive_min`, `idle_min`, `avg_kmh`, `max_kmh` | As in the raw trip file |
| `hard_brake`, `rapid_accel`, `overspeed` | Event counts |
| `start_lat/lon`, `end_lat/lon` | Only filled when `has_route = 1`; null otherwise because purged coordinates are fake |
| `gps_points` | Breadcrumb count |
| `has_route` | 1 if the GPS route survived (more than 1 point) |

**`trip_points`**: GPS breadcrumbs. Columns: `vehicle_id`, `trip_id`, `seq` (order), `ts` (minute-level
time), `lat`, `lon`.

**`snapshots`**: one row per sync. Columns: `vehicle_id`, `taken_at` (sync time), `status_time` (car's
last report), `odometer_km`, `fuel_pct`, `range_km`, `low_fuel`, `door_lock`, `engine_on`,
`battery_state`, `park_lat`, `park_lon`, `park_time`.

## `web/data.json` (dashboard input)

| Key | Contents |
|---|---|
| `generated_at` | When it was built |
| `vehicle` | `model`, `reg_date`, `year` |
| `status` | Latest odometer, fuel %, litres, range, lock, low-fuel, parked position |
| `totals` | Lifetime km, trips, hours, idle share, moving speed, archive coverage vs odometer, 90-day pace, event counts |
| `findings` | The plain-English headlines shown on each section |
| `days` | `[date, km, trips]` per day driven |
| `months` | `[YYYY-MM, km, trips, avg moving km/h]` |
| `rhythm` | 7×24 matrix: trip starts by weekday (Mon first) and hour |
| `weekday_km` | Average km per weekday |
| `idle_by_hour` | `[hour, idle share, trips]` for hours with 3+ trips |
| `trips` | Every trip: times, km, minutes, speeds, `events` `[brake, accel, speeding]`, `route` flag, `from`/`to` place names |
| `routes` | `{tripId: [[lat, lon, km/h, seconds from start], …]}`; speed is derived from GPS and smoothed |
| `places` | Frequent places: `Home`, `Work` (inferred), `Place N` (6+ visits) |
| `hotspots` | Spots where the car crawls below 8 km/h: minutes lost, trips, minutes per trip |
| `commute` | Home→work and work→home drives: start, minutes, km |
| `service` | Next due date per service item and whether distance or time triggers it |
| `milestones` | Dates the odometer crossed each 10,000 km |
| `fuel` | `[time, fuel %, range km]` per sync |

## Fuel log (`Sheet 1-Car Fuel.csv`)

| Column | Meaning | Notes |
|---|---|---|
| `Date` | Purchase date, e.g. `Wed, 19 Nov 2025` | Time of day unknown; `fuel.py` snaps each fill to the trip boundary that day that best fits its odometer |
| `Amount` | Rupees paid (`₹3,000.00`) | |
| `Location` | Station | Free text |
| `Quantity` | Litres | Missing once; recomputed as amount ÷ rate, borrowing the same station's rate |
| `@KM` | Odometer at the pump | Optional; logged rows calibrate the trip archive |
| `Rate` | ₹ per litre | Over 1.08 × your median price is treated as premium petrol |
| `Company` | Fuel brand | Optional |

## Derived quantities worth knowing

- **Per-trip distance correction (`delta`, ≈0.39 km)**: Bluelink rounds each trip's distance down to a whole km.
  `fuel.calibrate` estimates the loss from your logged odometer readings; lifetime km, coverage and all
  Performance/Fuel figures add it back (`km = distance_km + delta`). Raw per-trip distances are left as Bluelink reports them.
- **Brim-to-brim interval**: from one fill of 30 L or more to the next; litres burned = everything bought after the
  first up to and including the second. Intervals beating the 20.35 km/L type-approval figure hide an unlogged fill and are excluded.
- **Consumption model**: `litres = city_km/100·a + hwy_km/100·b + idle_h·c` with Gaussian priors from engine physics,
  noise chosen by maximum marginal likelihood. A trip is "highway" when Bluelink's average moving speed is at least 50 km/h.
- **Trip clusters**: k-means (k = 3) on standardised log distance, overall speed, idle share, top speed and log duration.
- **Cold start**: the engine had been parked at least 4 hours before the trip.
- **GPS speed and acceleration**: derived from breadcrumbs with minute-level timestamps spread evenly, then smoothed;
  accelerations are low-pass estimates, fine for comparing your trips but not for comparing against published drive cycles.
