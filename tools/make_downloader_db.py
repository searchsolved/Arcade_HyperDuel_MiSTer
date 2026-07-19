#!/usr/bin/env python3
"""Generate the MiSTer downloader/update_all database JSON for this repo.

Run from the repo root after tagging a release whose assets are the
current releases/ RBF and mra/ files:

    python3 tools/make_downloader_db.py

Writes hyperduel_db.json at the repo root. Users consume it by adding
to /media/fat/downloader.ini:

    [searchsolved/hyperduel]
    db_url = https://raw.githubusercontent.com/searchsolved/Arcade_HyperDuel_MiSTer/main/hyperduel_db.json

The db_id must equal the ini section name (lowercased); file URLs point
at the immutable GitHub release assets, so the raw db on main can be
regenerated freely without breaking old installs.
"""
import hashlib
import json
import time
import urllib.parse
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DB_ID = "searchsolved/hyperduel"
RELEASE_TAG = "v1.0"
RELEASE_BASE = (
    "https://github.com/searchsolved/Arcade_HyperDuel_MiSTer/releases/download/"
    + RELEASE_TAG + "/"
)

# (local path, install path on the MiSTer, release asset filename)
# NOTE: GitHub sanitises asset names - spaces and parens become dots -
# so the asset name differs from the install path for the MRAs.
FILES = [
    ("releases/Hyprduel_20260719.rbf", "_Arcade/cores/hyprduel_20260719.rbf",
     "Hyprduel_20260719.rbf"),
    ("mra/Hyper Duel.mra", "_Arcade/Hyper Duel.mra", "Hyper.Duel.mra"),
    ("mra/Hyper Duel (Set 2).mra", "_Arcade/Hyper Duel (Set 2).mra",
     "Hyper.Duel.Set.2.mra"),
]


def main():
    files = {}
    for local, install, asset in FILES:
        p = REPO_ROOT / local
        data = p.read_bytes()
        files[install] = {
            "hash": hashlib.md5(data).hexdigest(),
            "size": len(data),
            "url": RELEASE_BASE + urllib.parse.quote(asset),
        }
    db = {
        "db_id": DB_ID,
        "timestamp": int(time.time()),
        "files": files,
        "folders": {"_Arcade": {}, "_Arcade/cores": {}},
    }
    out = REPO_ROOT / "hyperduel_db.json"
    out.write_text(json.dumps(db, indent=2) + "\n")
    print(f"wrote {out}")
    for install, meta in files.items():
        print(f"  {install}  md5={meta['hash']}  {meta['size']} bytes")


if __name__ == "__main__":
    main()
