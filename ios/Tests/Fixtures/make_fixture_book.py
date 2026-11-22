"""Builds the synthetic fixture book for AnalyticsRunnerTests (no real data).

    uv run ios/Tests/Fixtures/make_fixture_book.py

Writes synthetic raw Bluelink responses (5 days, 3 trips, 2 snapshots), a 3-row fuel CSV and a
1-visit service log to a temp dir, runs tools/migrate.py on them and copies the result to
ios/Tests/Fixtures/book (replacing it).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
VID = "00000000-0000-4000-8000-000000000001"
DAYS = ["20261001", "20261002", "20261003", "20261004", "20261005"]
# (day, start HHMMSS, end HHMMSS, km, avg kmh, max kmh, drive min, idle min)
TRIPS = [("20261001", "080000", "102000", 140, 60, 95, 140, 6),
         ("20261003", "090000", "120000", 120, 40, 80, 180, 12),
         ("20261005", "070000", "093000", 140, 56, 90, 150, 8)]
BASE = (12.90, 77.50)  # synthetic coordinates


def ok(msg):
    return {"retCode": "S", "resCode": "0000", "resMsg": msg, "msgId": "00000000-0000-0000-0000-000000000000"}


def write(p: Path, obj, mtime=None):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj))
    if mtime:
        os.utime(p, (mtime, mtime))


def route(i, start, n=12):
    h, m, s = int(start[:2]), int(start[2:4]), 0
    pts = []
    for k in range(n):
        mm = m + k
        pts.append({"tripTime": f"{h + mm // 60:02d}{mm % 60:02d}{s:02d}",
                    "lat": round(BASE[0] + 0.01 * i + 0.004 * k, 6), "lon": round(BASE[1] + 0.005 * k, 6)})
    return pts


def build_src(src: Path):
    raw = src / "raw"
    final_mtime = 1792800000  # 2026-10-23, >= 7 days after every day -> final
    for d in DAYS:
        ts = [t for t in TRIPS if t[0] == d]
        lst = [{"tripDay": d, "dayTripCnt": len(ts), "tripDrvTime": t[6], "tripIdleTime": t[7], "tripDist": t[3],
                "tripAvgSpeed": t[4], "tripMaxSpeed": t[5]} for t in ts]
        write(raw / "days" / VID / f"{d}.json", ok({"tripPeriodType": 1, "dayTripList": lst}), final_mtime)
    for i, (d, st, en, km, avg, mx, drv, idle) in enumerate(TRIPS):
        pts = route(i, st)
        info = {"tripDay": d, "dayTripCnt": 1, "tripDrvTime": drv, "tripIdleTime": idle, "tripDist": km,
                "tripAvgSpeed": avg, "tripMaxSpeed": mx, "tripHardBreakingTime": i % 2, "tripRapidAccelationTime": 0,
                "tripExcessiveSpeedTime": 0, "tripStartTime": d + st, "tripEndTime": d + en,
                "tripStartCoord": {"tripStartTime": d + st, **{k: pts[0][k] for k in ("lat", "lon")}},
                "tripEndCoord": {"tripEndTime": d + en, **{k: pts[-1][k] for k in ("lat", "lon")}},
                "tripList": pts}
        write(raw / "trips" / VID / f"{d}{st}.json", ok({"tripInfo": info}))
    maint = [{"itemId": "Engine oil", "enable": True, "items": {"distValue": 10000, "termValue": 12}},
             {"itemId": "Air Cleaner", "enable": True, "items": {"distValue": 30000, "termValue": 36}}]
    for stamp, odo, fuel in (("20261002T200000", 1140, 70), ("20261005T200000", 1400, 80)):
        snap = raw / "snapshots" / VID / stamp
        write(snap / "vehicles.json", ok({"vehicles": [{"vin": "TESTVIN0000000000", "vehicleId": VID,
              "vehicleName": "i20", "nickname": "i20", "year": "2025", "regDate": "2025-11-25 10:11:34.839",
              "ccuCCS2ProtocolSupport": 0}]}))
        write(snap / "status_latest.json", ok({"engine": False, "doorLock": True, "lowFuelLight": False,
              "fuelLevel": fuel, "dte": {"value": 300, "unit": 1}, "battery": {"batState": 0},
              "time": stamp.replace("T", "")}))
        write(snap / "location_park.json", ok({"coord": {"lat": BASE[0], "lon": BASE[1], "alt": 0, "type": 0},
              "speed": {"value": 0, "unit": 0}, "time": stamp.replace("T", "")}))
        write(snap / "maintenance_alert.json", ok({"odometer": odo, "mainList": maint}))
    (src / "fuel.csv").write_text(
        "Date,Amount,Location,Quantity ,@KM,Rate,Company\n"
        '"Thu, 1 Oct 2026",₹3500.00,Test Pump,35.00,,₹100.00,HP\n'
        '"Sat, 3 Oct 2026",₹500.00,Test Pump,5.00,,₹100.00,HP\n'
        '"Mon, 5 Oct 2026",₹3000.00,Other Pump,30.00,,₹100.00,IOCL\n')
    (src / "service_log.json").write_text(json.dumps({"services": [{
        "date": "2026-10-02", "odometer_km": 1100, "kind": "Free service", "workshop": "Test Motors",
        "invoice": "INV-1", "parts": [{"code": "P-1", "name": "Engine oil", "qty": 3.5, "unit": "L",
                                       "amount": 1500, "resets": ["engine_oil"]}],
        "labour": [{"code": "L-1", "name": "Labour", "amount": 400}],
        "parts_total": 1500, "gst": 270, "total": 2170, "notes": "Synthetic visit"}]}))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        src, dest = Path(tmp) / "src", Path(tmp) / "i20_book"
        build_src(src)
        dest.mkdir()
        subprocess.run([sys.executable, str(ROOT / "tools" / "migrate.py"), "--dest", str(dest),
                        "--src-raw", str(src / "raw"), "--csv", str(src / "fuel.csv"),
                        "--service-log", str(src / "service_log.json")], check=True)
        out = HERE / "book"
        shutil.rmtree(out, ignore_errors=True)
        shutil.copytree(dest, out)
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
