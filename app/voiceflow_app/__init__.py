"""Native desktop companion for the local voiceflow daemon."""

from pathlib import Path as _Path


def _read_version() -> str:
    pyproject = _Path(__file__).resolve().parent.parent.parent / "pyproject.toml"
    try:
        for line in pyproject.read_text(encoding="utf-8").splitlines():
            if line.startswith("version"):
                return line.split('"')[1]
    except (OSError, IndexError):
        pass
    return "0.0.0"


__version__ = _read_version()
