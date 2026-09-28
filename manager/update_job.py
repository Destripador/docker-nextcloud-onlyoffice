import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def write_status(path, payload):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(2)

    root = Path(sys.argv[1]).resolve()
    state_dir = root / ".manager"
    log_path = state_dir / "update.log"
    lock_path = state_dir / "update.lock"
    status_path = state_dir / "update.status.json"
    state_dir.mkdir(mode=0o700, exist_ok=True)

    started = datetime.now(timezone.utc).isoformat()
    write_status(status_path, {"state": "running", "started_at": started})

    code = 1
    try:
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.run(
                ["bash", "scripts/update.sh", "--apply"],
                cwd=root,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=False,
            )
            code = process.returncode
    except Exception as exc:
        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"\n[ERROR] {exc}\n")

    finished = datetime.now(timezone.utc).isoformat()
    write_status(
        status_path,
        {
            "state": "success" if code == 0 else "failed",
            "exit_code": code,
            "started_at": started,
            "finished_at": finished,
        },
    )
    try:
        lock_path.unlink()
    except FileNotFoundError:
        pass
    raise SystemExit(code)


if __name__ == "__main__":
    main()
