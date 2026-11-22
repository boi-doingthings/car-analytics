# Log entry schemas

Single reference for Swift, JS (`analytics/src/logs.js`) and Python (`migrate.py`).
Each entry is one JSON file. Common fields on every entry:
- `schema`: always `1`. Readers ignore unknown fields; an entry with `schema` > 1 is skipped with a warning, never a crash.
- `id`: lowercase UUID v4; the file is `<id>.json` in the entry's folder.
- `entered_at`: ISO 8601 with the IST offset, whole seconds, e.g. `2026-10-25T18:31:07+05:30`.

## Refuel: `log/refuels/<id>.json`

```
{schema, id, entered_at,
 date: "YYYY-MM-DD", time: "HH:MM" | null,
 litres: number | null, amount: number | null, rate: number | null,
 odometer_km: number | null, full_tank: bool | null, missed: bool,
 station: string, company: string | null,
 lat: number | null, lon: number | null, note: string | null}
```

`amount` is rupees, `rate` rupees per litre. Any of litres/amount/rate may be missing; the fuel model
imputes them (see `fillsFromRefuels`).

### CSV mapping (`Sheet 1-Car Fuel.csv` -> refuel entry), 1:1

| CSV column | Entry field |
|---|---|
| Date (`Wed, 19 Nov 2025`) | `date` (ISO `2025-11-19`) |
| Amount (`₹3400.11`) | `amount` (number, `₹`/commas/spaces stripped) |
| Location | `station` (trimmed) |
| Quantity | `litres` |
| @KM | `odometer_km` |
| Rate (`₹94.50`) | `rate` |
| Company | `company` (empty -> `null`) |

Field semantics:
- `full_tank`: true = filled to the brim, false = partial, null = unknown (analytics falls back to litres >= 30).
- `missed`: true = a past fill logged after the fact; litres, amount, rate and odometer_km may be null.
- `lat`/`lon`: the pump's coordinates (phone location when the entry was saved), null if unknown.

Fixed for migrated rows: `full_tank: null, missed: false, time: null, lat/lon/note: null`. Empty cells become `null`.

## Service: `log/services/<id>.json`

```
{schema, id, entered_at,
 date: "YYYY-MM-DD", odometer_km: number | null,
 kind: string | null, workshop: string | null, invoice: string | null,
 parts: [{code: string, name: string, qty: number, unit?: string | null, amount: number, resets?: [string]}],
 labour: [{code: string, name: string, amount: number}],
 parts_total: number | null, gst: number | null, total: number | null,
 notes: string | null,
 photos: [string]}
```

- `qty` may be fractional (e.g. `3.6` with `unit: "L"`); `unit` is optional/nullable.
- `parts` and `labour` may be empty arrays.
- `resets` is optional and defaults to `[]` (real data has parts without it). It names the Bluelink
  maintenance items whose interval restarts at this visit.
- `photos` are file names inside `log/services/<id>/`.

## Maintenance: `log/maintenance/<id>.json`

```
{schema, id, entered_at, date, odometer_km: number | null,
 category: "tyres" | "battery" | "wipers" | "repair" | "insurance" | "puc" | "wash" | "other",
 cost: number, note: string | null, reminder: "YYYY-MM-DD" | null}
```

`reminder` is a date the owner wants to be reminded on, or null.

## Derived tables (JS)

- `fillsFromRefuels(entries)`: `date` (`YYYY-MM-DDT00:00:00`), `amount`, `litres`, `logged_km` (= `odometer_km`),
  `rate`, `station`, `brand` (= `company` or `"Unknown"`), `imputed` (`""|"rate"|"litres"`), `premium`
  (rate > median rate * 1.08), plus `full_tank`, `missed`, `time`, `id`, `entered_at`. Stable sort by date.
- `servicesFrom(entries)`: service entries sorted by date (stable), in `load_services()` shape plus `id`, `entered_at` (`resets` defaulted to `[]`).
- `maintenanceFrom(entries)`: maintenance entries sorted by date (stable).
