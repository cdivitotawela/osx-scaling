#!/usr/bin/env python3
"""Read-only CLI checks, including runners without connected displays."""
import json
from pathlib import Path
import subprocess
from typing import Any

BINARY = Path(__file__).resolve().parents[1] / "bin" / "scalectl"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(BINARY), *args], capture_output=True, text=True, check=False)


def read_json(*args: str) -> Any:
    result = run(*args)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def main() -> None:
    assert BINARY.is_file(), "Run scripts/build.sh first"
    assert run("help").returncode == 0
    displays = read_json("displays", "--json")
    configurations = read_json("show", "--json")
    assert isinstance(displays, list) and isinstance(configurations, list)
    assert {d["id"] for d in displays} == {d["id"] for d in configurations}
    for display in configurations:
        selector = display["uuid"] if display["uuid"] != "unavailable" else str(display["id"])
        selected = read_json("show", "--display", selector, "--json")
        assert len(selected) == 1 and selected[0]["id"] == display["id"]
        mode = selected[0]["currentMode"]
        assert abs(mode["renderScaleX"] - mode["pixelWidth"] / mode["width"]) < 1e-9
        assert abs(mode["renderScaleY"] - mode["pixelHeight"] / mode["height"]) < 1e-9
        modes = read_json("modes", "--display", selector, "--json")
        assert any(m["current"] and m["modeID"] == mode["modeID"] for m in modes)
        assert "Looks like:" in run("show", "--display", selector).stdout
    for args in [("show", "--display", "not-a-display"), ("show", "--display"),
                 ("show", "--aply"), ("unknown-command",), ("set", "--apply")]:
        assert run(*args).returncode != 0, args
    print(f"PASS read-only CLI checks ({len(configurations)} online displays)")


if __name__ == "__main__":
    main()
