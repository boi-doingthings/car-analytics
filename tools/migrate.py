"""One-time migration: Mac archive -> the owner's iCloud folder `i20_book`.

    uv run tools/migrate.py --dest ~/Library/Mobile\\ Documents/com~apple~CloudDocs/i20_book [--dry-run]

- copies data/raw/** -> <dest>/raw/** (shutil.copy2, mtimes kept) and writes
  raw/days/<vid>/<yyyymmdd>.meta.json = {"fetched_at": <day file mtime, IST ISO>} beside each day file;
- converts each row of `Sheet 1-Car Fuel.csv` -> log/refuels/<uuid>.json and each visit of
  service_log.json -> log/services/<uuid>.json (schemas: docs/entry-schemas.md);
- never overwrites: identical files (same sha256) are skipped, different ones raise, so reruns are safe.
  Entry ids are derived deterministically from the source row, so a rerun finds the same files; an
  existing entry is "identical" when everything but `entered_at` (the migration time) matches;
- never modifies the source; refuses unless dest ends with /i20_book; every write stays inside dest.
"""
import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IST = timezone(timedelta(hours=5, minutes=30))
MONTHS = {m: i + 1 for i, m in enumerate("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split())}
SKIP_NAMES = {".DS_Store"}


class MigrationError(Exception):
    pass


def iso_ist(ts: float) -> str:
    return datetime.fromtimestamp(ts, IST).strftime("%Y-%m-%dT%H:%M:%S+05:30")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_hash(root: Path) -> str:
    """Hash of every file's relative path, size, mtime and content (to prove the source is untouched)."""
    h = hashlib.sha256()
    for p in sorted(root.rglob("*")):
        if p.is_file():
            h.update(f"{p.relative_to(root)}|{p.stat().st_size}|{p.stat().st_mtime_ns}|{sha256(p)}\n".encode())
    return h.hexdigest()


def det_uuid(key: str) -> str:
    """Deterministic lowercase UUID v4-shaped id, so reruns map each source row to the same file."""
    return str(uuid.UUID(bytes=hashlib.sha256(key.encode()).digest()[:16], version=4))


def num(s):
    t = re.sub(r"[₹,\s]", "", s or "")
    if t == "":
        return None
    v = float(t)
    return int(v) if v.is_integer() and "." not in t else v


def refuel_entries(csv_path: Path, now: str) -> list[dict]:
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    header = [h.strip() for h in rows[0]]
    out = []
    for i, r in enumerate(x for x in rows[1:] if any(c.strip() for c in x)):
        c = dict(zip(header, r))
        d, mon, y = re.search(r"(\d+) (\w{3}) (\d{4})", c["Date"]).groups()
        eid = det_uuid(f"refuel:{i}:{','.join(r)}")
        out.append({
            "schema": 1, "id": eid, "entered_at": now,
            "date": f"{y}-{MONTHS[mon]:02d}-{int(d):02d}", "time": None,
            "litres": num(c["Quantity"]), "amount": num(c["Amount"]), "rate": num(c["Rate"]),
            "odometer_km": num(c["@KM"]), "full_tank": None, "missed": False,
            "station": c["Location"].strip(), "company": c["Company"].strip() or None,
            "lat": None, "lon": None, "note": None,
        })
    return out


def service_entries(path: Path, now: str) -> list[dict]:
    out = []
    for i, v in enumerate(json.loads(path.read_text())["services"]):
        out.append({
            "schema": 1, "id": det_uuid(f"service:{i}:{json.dumps(v, sort_keys=True)}"), "entered_at": now,
            "date": v["date"], "odometer_km": v.get("odometer_km"),
            "kind": v.get("kind"), "workshop": v.get("workshop"), "invoice": v.get("invoice"),
            "parts": v.get("parts", []), "labour": v.get("labour", []),
            "parts_total": v.get("parts_total"), "gst": v.get("gst"), "total": v.get("total"),
            "notes": v.get("notes"), "photos": [],
        })
    return out


def migrate(dest, *, src_raw=None, csv_path=None, service_log=None, dry_run=False, now=None, out=print) -> dict:
    src_raw = Path(src_raw or ROOT / "data" / "raw")
    csv_path = Path(csv_path or ROOT / "Sheet 1-Car Fuel.csv")
    service_log = Path(service_log or ROOT / "service_log.json")
    dest = Path(os.path.abspath(os.path.expanduser(str(dest))))
    if dest.name != "i20_book":
        raise MigrationError(f"refusing: dest must end with /i20_book (got {dest})")
    if dest.is_symlink():
        raise MigrationError(f"refusing: dest is a symlink ({dest})")
    base = dest.resolve()
    if base.name != "i20_book":
        raise MigrationError(f"refusing: dest resolves to {base}, which is not named i20_book")
    now = now or datetime.now(IST).strftime("%Y-%m-%dT%H:%M:%S+05:30")
    before = tree_hash(src_raw)

    try:
        refuels = refuel_entries(csv_path, now)
        services = service_entries(service_log, now)
        files = sorted(p for p in src_raw.rglob("*") if p.is_file() and p.name not in SKIP_NAMES)
    except (OSError, ValueError, KeyError, AttributeError, IndexError) as e:
        raise MigrationError(f"cannot read source data: {type(e).__name__}: {e}") from e

    def inside(p: Path) -> Path:
        r = p.resolve()
        if r != base and base not in r.parents:
            raise MigrationError(f"refusing to write outside {base}: {r}")
        return p

    # Plan: (target, kind, data bytes | source file, same(target) -> bool)
    plan = []
    for s in files:
        rel = s.relative_to(src_raw)
        plan.append((dest / "raw" / rel, "raw", s, lambda d, s=s: sha256(d) == sha256(s)))
        if rel.parts[0] == "days" and len(rel.parts) == 3 and re.fullmatch(r"\d{8}\.json", rel.name):
            meta = json.dumps({"fetched_at": iso_ist(s.stat().st_mtime)}, indent=2).encode()
            plan.append((dest / "raw" / rel.with_suffix(".meta.json"), "meta", meta, lambda d, m=meta: d.read_bytes() == m))
    for folder, entries in (("refuels", refuels), ("services", services)):
        for e in entries:
            body = (json.dumps(e, indent=2, ensure_ascii=False) + "\n").encode()

            def same(d, e=e):
                try:
                    old = json.loads(d.read_text())
                except ValueError:
                    return False
                strip = lambda x: {k: v for k, v in x.items() if k != "entered_at"}  # noqa: E731
                return strip(old) == strip(e)
            plan.append((dest / "log" / folder / f"{e['id']}.json", folder, body, same))

    # Preflight: every containment and conflict check happens before the first write.
    todo, stats = [], {}
    for kind in ("raw", "meta", "refuels", "services"):
        stats[f"{kind}_written"] = stats[f"{kind}_skipped"] = 0
    for target, kind, data, same in plan:
        inside(target)
        if target.exists():
            if not same(target):
                raise MigrationError(f"{target} exists with different content; not overwriting")
            stats[f"{kind}_skipped"] += 1
        else:
            todo.append((target, data))
            stats[f"{kind}_written"] += 1

    if not dry_run:
        for target, data in todo:
            target.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=target.parent, prefix=".tmp-", suffix=".part")  # never *.json
            os.close(fd)
            try:
                if isinstance(data, Path):
                    shutil.copy2(data, tmp)  # keeps mtime
                else:
                    Path(tmp).write_bytes(data)
                os.replace(tmp, target)
            except BaseException:
                Path(tmp).unlink(missing_ok=True)
                raise

        # Verify: hashes and mtimes of raw files, exact entry counts and re-read contents.
        for s in files:
            d = dest / "raw" / s.relative_to(src_raw)
            if sha256(d) != sha256(s):
                raise MigrationError(f"verification failed: sha256 differs for {d}")
            if d.stat().st_mtime_ns != s.stat().st_mtime_ns:
                raise MigrationError(f"verification failed: mtime differs for {d}")
        for folder, entries, expected in (("refuels", refuels, len(refuels)), ("services", services, len(services))):
            for e in entries:
                path = dest / "log" / folder / f"{e['id']}.json"
                try:
                    got = json.loads(path.read_text())
                except (OSError, ValueError) as err:
                    raise MigrationError(f"verification failed: cannot read {path}: {err}") from err
                if {k: v for k, v in got.items() if k != "entered_at"} != {k: v for k, v in e.items() if k != "entered_at"}:
                    raise MigrationError(f"verification failed: content differs for {path}")
            have = {p.stem for p in (dest / "log" / folder).glob("*.json")}
            found = len({e["id"] for e in entries} & have)  # later app entries may sit beside these
            if found != expected:
                raise MigrationError(f"verification failed: {found} {folder} entries present, expected {expected}")
    if tree_hash(src_raw) != before:
        raise MigrationError("source tree changed during migration")

    stats.update(raw_files=len(files), csv_rows=len(refuels), visits=len(services), dry_run=dry_run, dest=str(dest))
    out(("DRY RUN (nothing written)\n" if dry_run else "") + json.dumps(stats, indent=2))
    return stats


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dest", required=True, help="the i20_book folder")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--src-raw"), ap.add_argument("--csv"), ap.add_argument("--service-log")
    a = ap.parse_args(argv)
    try:
        migrate(a.dest, src_raw=a.src_raw, csv_path=a.csv, service_log=a.service_log, dry_run=a.dry_run)
    except MigrationError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
