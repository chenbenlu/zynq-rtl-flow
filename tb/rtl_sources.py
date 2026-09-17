"""The RTL source list, read from the one file that holds it.

``scripts/rtl_sources.sh`` is what lint, ``make sec`` and both synthesis flows
read. The cocotb seams read it through here rather than restating it, so a new
source is added in one place and every consumer sees it.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_LIST = PROJECT_ROOT / "scripts" / "rtl_sources.sh"


def sources_for(top: str) -> list[Path]:
    """Absolute paths to the sources needed to elaborate ``top``."""
    listing = subprocess.run(
        ["bash", "-c", f'source "{SOURCE_LIST}"; rtl_sources_for "$1"', "_", top],
        capture_output=True,
        text=True,
        check=True,
        cwd=PROJECT_ROOT,
    )
    return [PROJECT_ROOT / line for line in listing.stdout.split()]
