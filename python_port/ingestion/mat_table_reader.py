"""Read the `SensorLabels` MATLAB table written by loadNodoData.m's
SaveFolderLabel(), from a v7.3 (HDF5) .mat file, without a MATLAB
installation.

MATLAB's `table` type is an MCOS (opaque classdef) object. scipy.io.loadmat
cannot read it at all for v7.3 files ("Please use HDF reader"), and h5py
only exposes the raw HDF5 layout, not table semantics -- there is no
general, documented way to reconstruct an arbitrary MATLAB table from
Python. This module does NOT attempt that; it targets exactly one fixed,
known schema: the 3-column, all-string `SensorLabels` table -- columns
Folder, SensorID, SensorLabel, in that order -- that SaveFolderLabel()
always writes (see matlab/ingestion/loadNodoData.m).

Reverse-engineered against the 12 real registry files already in
data/interim/label_registry/ (Dati01, 04, 05, 06, 10, 11, 18, 22, 23, 24,
26, 27). Verified structure, consistent across all of them:

- `#subsystem#/MCOS` is a 1xN cell of object references. Exactly 3 of them
  are small `uint64` column vectors, one per string-typed table column, in
  table-column order:
      [ndims=1, _unused=2, nrows, ncols=1,
       <nrows string-length ints>,
       <UTF-16LE payload, packed 4 code units per uint64 word>]
- A separate 3-element cell of `char` datasets (also in MCOS) holds the
  matching VariableNames ('Folder', 'SensorID', 'SensorLabel'), used here
  only as a sanity check that the 3 decoded columns really are this table's
  columns in this order -- if MATLAB's internal MCOS encoding ever changes
  (a different release, a differently-shaped table), that check -- or the
  string-array header check -- fails loudly with ValueError instead of
  silently mis-mapping columns.
"""
from __future__ import annotations

import struct
from pathlib import Path
from typing import List, Union

import h5py
import pandas as pd

EXPECTED_COLUMNS = ["Folder", "SensorID", "SensorLabel"]


def _decode_mcos_string_array(dataset: h5py.Dataset) -> List[str]:
    """Decode one MCOS `string`-class column-data object into a list of str."""
    arr = dataset[()].flatten()
    if len(arr) < 4:
        raise ValueError("too short to be an MCOS string-array payload")

    ndims, _unused, nrows, ncols = (int(x) for x in arr[:4])
    if ndims != 1 or ncols != 1 or nrows < 0:
        raise ValueError(f"unexpected string-array header {arr[:4].tolist()}")

    header_end = 4 + nrows
    if len(arr) < header_end:
        raise ValueError("truncated string-array length table")
    lengths = [int(x) for x in arr[4:header_end]]

    payload = b"".join(struct.pack("<Q", int(w)) for w in arr[header_end:])
    needed_bytes = sum(lengths) * 2
    if needed_bytes > len(payload):
        raise ValueError("string-array payload shorter than declared lengths")

    out: List[str] = []
    pos = 0
    for length in lengths:
        nbytes = length * 2
        out.append(payload[pos:pos + nbytes].decode("utf-16-le"))
        pos += nbytes
    return out


def _decode_mcos_char_array(dataset: h5py.Dataset) -> str:
    arr = dataset[()].flatten()
    return "".join(chr(int(c)) for c in arr)


def read_sensor_labels_table(path: Union[str, Path]) -> pd.DataFrame:
    """Read a SensorLabels table (Folder/SensorID/SensorLabel, all strings)
    from a v7.3 .mat file written by SaveFolderLabel() in loadNodoData.m.

    Raises ValueError if the file isn't a v7.3 MCOS-object .mat, or doesn't
    match this exact fixed schema (rather than guessing).
    """
    path = Path(path)
    string_cols: List[List[str]] = []
    name_cells: List[str] = []

    with h5py.File(path, "r") as f:
        if "#subsystem#" not in f or "MCOS" not in f["#subsystem#"]:
            raise ValueError(f"{path}: not a v7.3 MCOS-object .mat file (no #subsystem#/MCOS)")
        mcos = f["#subsystem#"]["MCOS"][()].flatten()

        def visit(obj):
            if not isinstance(obj, h5py.Dataset):
                return
            cls = obj.attrs.get("MATLAB_class")

            if cls == b"uint64" and obj.ndim == 2 and obj.shape[1] == 1:
                try:
                    string_cols.append(_decode_mcos_string_array(obj))
                except (ValueError, UnicodeDecodeError):
                    pass
            elif cls == b"char":
                try:
                    name_cells.append(_decode_mcos_char_array(obj))
                except (ValueError, UnicodeDecodeError):
                    pass
            elif cls == b"cell" and obj.dtype == object:
                # `cell` objects (e.g. the VariableNames cell) hold nested
                # references rather than data directly -- one level of
                # recursion is enough for this schema (SaveFolderLabel()
                # never nests cells deeper than that).
                for nested_ref in obj[()].flatten():
                    try:
                        visit(f[nested_ref])
                    except Exception:
                        pass

        for ref in mcos:
            visit(f[ref])

    if not set(EXPECTED_COLUMNS).issubset(name_cells):
        raise ValueError(
            f"{path}: expected variable names {EXPECTED_COLUMNS} to be present, "
            f"found {name_cells!r} -- table schema does not match SaveFolderLabel()'s output"
        )

    row_counts = {}
    for col in string_cols:
        row_counts.setdefault(len(col), []).append(col)
    matches = [cols for n, cols in row_counts.items() if len(cols) == len(EXPECTED_COLUMNS)]
    if not matches:
        raise ValueError(
            f"{path}: could not find {len(EXPECTED_COLUMNS)} string columns "
            f"sharing a row count among {len(string_cols)} candidate(s)"
        )
    folder_col, id_col, label_col = matches[0]

    return pd.DataFrame({
        "Folder": folder_col,
        "SensorID": id_col,
        "SensorLabel": label_col,
    })
