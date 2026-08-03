"""Low-level binary readers mirroring MATLAB's fread(fid, count, precision) semantics.

MATLAB's fread returns however many elements were actually read (fewer at EOF
or on a truncated stream) rather than raising. All packet parsers in this
port (read_pjm_file.py, load_nodo_data.py) rely on that "short read" signal
to reproduce the original truncation/EOF handling exactly, so it is centralized
here instead of using plain struct.unpack (which raises on short data).
"""
from __future__ import annotations

from typing import BinaryIO, Optional, Tuple

import numpy as np

# All source files were written on a little-endian platform (MATLAB default
# 'native' machine format on Windows); every dtype below is explicitly '<'.
_DTYPES = {
    "uint8": np.dtype("<u1"),
    "int8": np.dtype("<i1"),
    "uint16": np.dtype("<u2"),
    "int16": np.dtype("<i2"),
    "uint32": np.dtype("<u4"),
    "int32": np.dtype("<i4"),
    "uint64": np.dtype("<u8"),
    "int64": np.dtype("<i8"),
    "float32": np.dtype("<f4"),
    "float64": np.dtype("<f8"),
}


def fread(f: BinaryIO, precision: str, count: int = 1) -> Tuple[np.ndarray, int]:
    """Mirror MATLAB's [values, n] = fread(fid, count, precision).

    Returns a 1-D array of length <= count (short at EOF/truncation) and the
    number of elements actually read.
    """
    dtype = _DTYPES[precision]
    raw = f.read(dtype.itemsize * count)
    n_read = len(raw) // dtype.itemsize
    if n_read == 0:
        return np.array([], dtype=dtype), 0
    values = np.frombuffer(raw, dtype=dtype, count=n_read)
    return values, n_read


def fread1(f: BinaryIO, precision: str) -> Optional[float]:
    """Read a single scalar. Returns None on EOF/truncation (MATLAB: isempty(x))."""
    values, n_read = fread(f, precision, 1)
    if n_read < 1:
        return None
    return values[0].item()
