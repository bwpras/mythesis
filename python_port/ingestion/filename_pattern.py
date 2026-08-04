"""Shared `.bin` filename convention: `<YYYY>_<MMDD><HH><MN><SS>...<kind>.bin`
where `<kind>` is `p` (pressure) or `pjm` (GPS), plus an optional
`_<0xHEX>_` kit-ID segment. Extracted from what used to be two
independently-declared copies of the same regex in `load_nodo_data.py` and
`batch_process.py` -- a third near-copy in the live watcher/replay tool
would be one drift risk too many.
"""
from __future__ import annotations

import re
from typing import Optional, Tuple

import numpy as np

FNAME_RE = re.compile(
    r"^(?P<YYYY>\d{4})_(?P<MMDD>\d{4})(?P<HH>\d{2})(?P<MN>\d{2})(?P<SS>\d{2}).*?_(?P<kind>pjm|p)\.bin$"
)
KITID_RE = re.compile(r"_(0x[0-9a-fA-F]+)_")


def parse_bin_filename(name: str) -> Optional[Tuple[np.datetime64, str, str]]:
    """Returns (end_time, kind, kit_id) or None if `name` doesn't match the
    convention. `kit_id` is `""` if no `_0xHEX_` segment is present."""
    m = FNAME_RE.match(name)
    if not m:
        return None
    g = m.groupdict()
    end_time = np.datetime64(
        f"{g['YYYY']}-{g['MMDD'][:2]}-{g['MMDD'][2:]}T{g['HH']}:{g['MN']}:{g['SS']}"
    )
    kit_m = KITID_RE.search(name)
    kit_id = kit_m.group(1) if kit_m else ""
    return end_time, g["kind"], kit_id


def file_end_time(name: str) -> Optional[np.datetime64]:
    """`parse_bin_filename()`, just the timestamp -- matches
    `batch_process.py`'s original narrower need."""
    parsed = parse_bin_filename(name)
    return parsed[0] if parsed is not None else None
