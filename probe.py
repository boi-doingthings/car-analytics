"""Phase 0 probe: log in to Bluelink India and dump every raw response we can get.

Read-only. Uses only cached server-side data (never wakes the car), and saves
each response verbatim under data/raw/<run timestamp>/ so nothing is lost even
if our parsing is wrong later.

Usage:  uv run probe.py [--months N] [--end YYYYMM]   (default: last 4 months up to now)
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

REGION_INDIA = 6
BRAND_HYUNDAI = 2
PAUSE_S = 0.6  # be gentle with the API

ROOT = Path(__file__).parent
RUN_DIR = ROOT / "data" / "raw" / dt.datetime.now().strftime("%Y%m%dT%H%M%S")


def save(name: str, payload) -> None:
    path = RUN_DIR / f"{name}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False, default=str))


def fetch(api, method: str, url: str, headers: dict, body: dict | None = None) -> dict:
    time.sleep(PAUSE_S)
    if method == "GET":
        resp = api.session.get(url, headers=headers)
    else:
        resp = api.session.post(url, json=body, headers=headers)
    try:
        return resp.json()
    except ValueError:
        return {"_http_status": resp.status_code, "_text": resp.text[:2000]}


def ok(resp: dict) -> bool:
    return resp.get("retCode") == "S" or "resMsg" in resp


def month_starts(n: int, end: str | None = None) -> list[str]:
    last = dt.datetime.strptime(end, "%Y%m").date() if end else dt.date.today()
    out = []
    for i in range(n):
        y, m = divmod(last.year * 12 + last.month - 1 - i, 12)
        out.append(f"{y}{m + 1:02d}")
    return out


def probe_vehicle(api, token, vehicle, months: int, end: str | None, report: dict) -> None:
    vid = vehicle.id
    base = api.SPA_API_URL + "vehicles/" + vid
    hdr = api._get_vehicle_headers(token, vehicle)
    status_path = "/status/latest" if vehicle.ccu_ccs2_protocol_support == 0 else "/ccs2/carstatus/latest"

    simple = {
        "status_latest": ("GET", base + status_path, None),
        "location_park": ("GET", base + "/location/park", None),
        "maintenance_alert": ("GET", base + "/setting/alert/maintenance", None),
        "drvhistory_30d": ("POST", base + "/drvhistory", {"periodTarget": 0}),
        "drvhistory_alltime": ("POST", base + "/drvhistory", {"periodTarget": 1}),
    }
    for name, (method, url, body) in simple.items():
        resp = fetch(api, method, url, hdr, body)
        save(f"{vid}/{name}", resp)
        report["endpoints"][name] = "ok" if ok(resp) else f"FAIL: {str(resp)[:200]}"

    trips_url = base + "/tripinfo"
    detail_url = base + "/tripinfo/detail"
    for yyyymm in month_starts(months, end):
        resp = fetch(api, "POST", trips_url, hdr, {"tripPeriodType": 0, "setTripMonth": yyyymm})
        save(f"{vid}/trips/month_{yyyymm}", resp)
        days = (resp.get("resMsg") or {}).get("tripDayList", [])
        report["months"][yyyymm] = {"ok": ok(resp), "days_with_trips": len(days), "trips": 0}
        if not ok(resp):
            report["months"][yyyymm]["error"] = str(resp)[:200]
            continue

        for day in days:
            yyyymmdd = day["tripDayInMonth"]
            dresp = fetch(api, "POST", trips_url, hdr, {"tripPeriodType": 1, "setTripDay": yyyymmdd})
            save(f"{vid}/trips/day_{yyyymmdd}", dresp)
            for day_entry in (dresp.get("resMsg") or {}).get("dayTripList", []):
                for trip in day_entry.get("tripList", []):
                    report["months"][yyyymm]["trips"] += 1
                    # India's day list may only hold a summary; pull per-trip detail when we can.
                    if "serviceTID" not in trip:
                        continue
                    body = {
                        "tripPeriodType": 1,
                        "setTripDay": yyyymmdd,
                        "setTripStartTime": trip.get("tripStartTime"),
                        "setServiceTID": trip["serviceTID"],
                        "tripStartTime": trip.get("tripStartTime"),
                        "tripEndTime": trip.get("tripEndTime"),
                    }
                    tresp = fetch(api, "POST", detail_url, hdr, body)
                    save(f"{vid}/trips/detail_{yyyymmdd}_{trip.get('tripStartTime', 'x')}", tresp)
                    report["detail_calls"] += 1
                    if ok(tresp):
                        report["detail_ok"] += 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--months", type=int, default=4)
    parser.add_argument("--end", help="last month to fetch, YYYYMM (default: current month)")
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")
    username = os.environ.get("BLUELINK_USERNAME")
    password = os.environ.get("BLUELINK_PASSWORD")
    if not username or not password:
        print("Set BLUELINK_USERNAME and BLUELINK_PASSWORD in .env first.")
        return 1

    vm = VehicleManager(
        region=REGION_INDIA,
        brand=BRAND_HYUNDAI,
        username=username,
        password=password,
        pin=os.environ.get("BLUELINK_PIN", ""),
    )
    print("Logging in...")
    result = vm.login()
    if result is not True:
        print(f"Login needs OTP or failed: {result!r}")
        return 1

    api, token = vm.api, vm.token
    save("vehicles", fetch(api, "GET", api.SPA_API_URL + "vehicles", api._get_authenticated_headers(token)))

    for vehicle in vm.vehicles.values():
        print(f"Probing {vehicle.name} ({vehicle.model}, engine={vehicle.engine_type}, ccs2={vehicle.ccu_ccs2_protocol_support})")
        report = {"vehicle": vehicle.model, "endpoints": {}, "months": {}, "detail_calls": 0, "detail_ok": 0}
        probe_vehicle(api, token, vehicle, args.months, args.end, report)
        save(f"{vehicle.id}/_report", report)
        print(json.dumps(report, indent=2))

    print(f"\nRaw data saved to {RUN_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
