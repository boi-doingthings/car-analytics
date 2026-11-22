"""Collector: archive Bluelink India data to data/raw/ before Hyundai purges it.

Read-only (never wakes the car). Layout:
  data/raw/snapshots/<vid>/<ts>/{vehicles,status_latest,location_park,maintenance_alert}.json
  data/raw/days/<vid>/<yyyymmdd>.json     day summary + trip list
  data/raw/trips/<vid>/<serviceTID>.json  per-trip detail incl. GPS breadcrumbs

Hyundai keeps per-day/per-trip stats long-term but drops GPS routes after ~3
months (coords get replaced with the current parking spot). A day file is final
once it was fetched at least RECENT_DAYS after that day; final files are never
overwritten, since a later fetch could only be worse. Each run resumes from the
earliest missing or non-final day, so skipped runs leave no gaps (up to the ~3
month GPS limit).

Usage:
  uv run collect.py                      # regular run: snapshot + every day not yet final
  uv run collect.py --since 20251101     # backfill every day from that date
"""

import argparse
import datetime as dt
import json
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv
from hyundai_kia_connect_api import VehicleManager
from hyundai_kia_connect_api.exceptions import RequestTimeoutError

REGION_INDIA = 6
BRAND_HYUNDAI = 2
PAUSE_S = 0.6
RECENT_DAYS = 7  # trips may still be landing / settling within this window

ROOT = Path(__file__).parent
RAW = ROOT / "data" / "raw"


def write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=1, ensure_ascii=False, default=str))
    tmp.replace(path)


def fetch(api, method: str, url: str, headers: dict, body: dict | None = None) -> dict:
    time.sleep(PAUSE_S)
    if method == "GET":
        resp = api.session.get(url, headers=headers, timeout=30)
    else:
        resp = api.session.post(url, json=body, headers=headers, timeout=30)
    try:
        return resp.json()
    except ValueError:
        return {"_http_status": resp.status_code, "_text": resp.text[:2000]}


def is_ok(resp: dict) -> bool:
    return resp.get("retCode") == "S"


def is_final(path: Path, day: dt.date) -> bool:
    """True if the saved day file was fetched after the day had settled."""
    return path.exists() and (dt.date.fromtimestamp(path.stat().st_mtime) - day).days >= RECENT_DAYS


def point_count(path: Path) -> int:
    try:
        info = json.loads(path.read_text())["resMsg"]["tripInfo"]
        return len(info.get("tripList") or [])
    except (OSError, KeyError, TypeError, ValueError):
        return 0


class Collector:
    def __init__(self, vm: VehicleManager, vehicle):
        self.api, self.token, self.v = vm.api, vm.token, vehicle
        self.base = self.api.SPA_API_URL + "vehicles/" + vehicle.id
        self.hdr = self.api._get_vehicle_headers(self.token, vehicle)
        self.stats = {"days_fetched": 0, "days_skipped": 0, "trips_fetched": 0, "trips_skipped": 0, "errors": []}

    def snapshot(self) -> None:
        status = "/status/latest" if self.v.ccu_ccs2_protocol_support == 0 else "/ccs2/carstatus/latest"
        ts = dt.datetime.now().strftime("%Y%m%dT%H%M%S")
        for name, url in [("vehicles", self.api.SPA_API_URL + "vehicles"),
                          ("status_latest", self.base + status), ("location_park", self.base + "/location/park"),
                          ("maintenance_alert", self.base + "/setting/alert/maintenance")]:
            resp = fetch(self.api, "GET", url, self.hdr)
            if is_ok(resp):
                write_json(RAW / "snapshots" / self.v.id / ts / f"{name}.json", resp)
            else:
                self.stats["errors"].append(f"{name}: {str(resp)[:150]}")

    def resume_from(self, today: dt.date) -> dt.date:
        """Earliest day that is missing or not final, never later than the RECENT_DAYS window."""
        floor = today - dt.timedelta(days=RECENT_DAYS)
        saved = sorted((RAW / "days" / self.v.id).glob("*.json"))
        if not saved:
            return floor
        day = dt.datetime.strptime(saved[0].stem, "%Y%m%d").date()
        while day < floor and is_final(RAW / "days" / self.v.id / f"{day:%Y%m%d}.json", day):
            day += dt.timedelta(days=1)
        return day

    def day(self, day: dt.date) -> None:
        key = day.strftime("%Y%m%d")
        path = RAW / "days" / self.v.id / f"{key}.json"
        recent = not is_final(path, day)
        if not recent:
            self.stats["days_skipped"] += 1
            trips = self._trips_in(json.loads(path.read_text()))
        else:
            resp = fetch(self.api, "POST", self.base + "/tripinfo", self.hdr,
                         {"tripPeriodType": 1, "setTripDay": key})
            if not is_ok(resp):
                self.stats["errors"].append(f"day {key}: {str(resp)[:150]}")
                return
            write_json(path, resp)
            self.stats["days_fetched"] += 1
            trips = self._trips_in(resp)
        for trip in trips:
            self.trip(key, trip, recent)

    @staticmethod
    def _trips_in(resp: dict) -> list[dict]:
        return [t for d in (resp.get("resMsg") or {}).get("dayTripList", []) for t in d.get("tripList", [])]

    def trip(self, key: str, trip: dict, recent: bool) -> None:
        path = RAW / "trips" / self.v.id / f"{trip['serviceTID']}.json"
        # Refetch only recent trips whose route hasn't arrived yet; never touch older files.
        if path.exists() and (not recent or point_count(path) > 1):
            self.stats["trips_skipped"] += 1
            return
        resp = fetch(self.api, "POST", self.base + "/tripinfo/detail", self.hdr, {
            "tripPeriodType": 1,
            "setTripDay": key,
            "setTripStartTime": trip["tripStartTime"],
            "setServiceTID": trip["serviceTID"],
            "tripStartTime": trip["tripStartTime"],
            "tripEndTime": trip["tripEndTime"],
        })
        if is_ok(resp) and (resp.get("resMsg") or {}).get("tripInfo"):
            write_json(path, resp)
            self.stats["trips_fetched"] += 1
        else:
            self.stats["errors"].append(f"trip {trip['serviceTID']}: {str(resp)[:150]}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--since", help="backfill from this day, YYYYMMDD")
    parser.add_argument("--no-snapshot", action="store_true")
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")
    username, password = os.environ.get("BLUELINK_USERNAME"), os.environ.get("BLUELINK_PASSWORD")
    if not username or not password:
        print("Set BLUELINK_USERNAME and BLUELINK_PASSWORD in .env first.")
        return 1

    vm = VehicleManager(region=REGION_INDIA, brand=BRAND_HYUNDAI, username=username,
                        password=password, pin=os.environ.get("BLUELINK_PIN", ""))
    # Hyundai's India server sometimes stalls; one patient retry covers most of it.
    for attempt in range(2):
        try:
            ok = vm.login() is True
            break
        except RequestTimeoutError:
            if attempt:
                raise
            print("Hyundai's server timed out; retrying in 15 s.")
            time.sleep(15)
    if not ok:
        print("Login failed or needs OTP.")
        return 1

    today = dt.date.today()
    started = time.time()
    for vehicle in vm.vehicles.values():
        c = Collector(vm, vehicle)
        if not args.no_snapshot:
            c.snapshot()
        day = dt.datetime.strptime(args.since, "%Y%m%d").date() if args.since else c.resume_from(today)
        print(f"{vehicle.model}: syncing {day} .. {today}")
        while day <= today:
            c.day(day)
            day += dt.timedelta(days=1)
        print(f"{dt.datetime.now():%Y-%m-%d %H:%M} {vehicle.model}: {json.dumps(c.stats)} ({time.time() - started:.0f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
