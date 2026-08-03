"""Port of archive/matlab_legacy/algorithm_feature_extraction_outer/detect_subphases_sets.m
(a functionally-identical copy also exists at
archive/matlab_legacy/algorithm_experiment_backup/detect_subphases_sets.m --
the two differ only in error-stack verbosity, not behavior).

This file is called by the active `matlab/main/Algorithm_main_batch.m`, but
does not exist anywhere in the active `matlab/` tree -- only in the two
archived copies above (see `docs/unresolved_issues.md`). Ported against the
archived source as ground truth, since it is what the active pipeline
actually depends on.

Thin orchestration wrapper: runs `detect_mbp_pipe_subphases` then
`detect_bc_cyl_subphases` over each pair's phase list (one element of
`build_test_brake_sets`'s `test_brake_sets`), isolating failures per pair,
per detector -- a failure in one detector does not block the other, or any
other pair, and the wrapper itself never raises.

Deviations from the MATLAB source (documented, not silent):
  - The source supports an arbitrary M x N cell-array shape via a
    linearize-then-reshape dance (`TBsets(:).'` ... `reshape(TB_out_row, sz)`),
    because MATLAB cell arrays can be multi-dimensional. `build_test_brake_sets.py`
    always returns a flat `list[list[dict]]` (MATLAB's `1 x npairs` shape),
    so the reshape step is dead code for this pipeline; a plain list is
    used instead.
  - `UseParfor` (unused by the actual pipeline call, which is always
    serial) is not exposed as a parameter here.
  - **Fidelity fix, not a bug in the source but a necessary adaptation for
    Python's mutation model.** `detect_mbp_pipe_subphases`/
    `detect_bc_cyl_subphases` mutate each phase dict in place. MATLAB is
    pass-by-value: if a detector call errors partway through processing a
    struct array, the caller's variable is left completely untouched (not
    partially mutated) -- "keep S unchanged" in the source comment means
    exactly that. A naive Python port that mutates the shared list of
    dicts directly would leave *partial* mutations visible after a
    mid-call exception, which is a real behavioral difference. This port
    passes each detector a fresh shallow copy of the phase-dict list
    (`[dict(p) for p in cell]` -- cheap: only copies key/value pairs, not
    the underlying numpy arrays) and only commits the result back if the
    call succeeds, matching MATLAB's true all-or-nothing semantics.
"""
from __future__ import annotations

from typing import Optional

from .mbp_pipe_subphases import detect_mbp_pipe_subphases
from .bc_cyl_subphases import detect_bc_cyl_subphases


def detect_subphases_sets(
    test_brake_sets: list,
    *,
    mbp_kwargs: Optional[dict] = None,
    bc_kwargs: Optional[dict] = None,
    verbose: bool = False,
) -> list:
    mbp_kwargs = mbp_kwargs or {}
    bc_kwargs = bc_kwargs or {}
    out = []

    for idx, cell in enumerate(test_brake_sets):
        if not cell:
            if verbose:
                print(f"[{idx}] empty cell -> passthrough")
            out.append(cell)
            continue

        s = cell

        try:
            candidate = [dict(phase) for phase in s]
            candidate = detect_mbp_pipe_subphases(candidate, **mbp_kwargs)
            s = candidate
            if verbose:
                print(f"[{idx}] MBP done ({len(s)} phases)")
        except Exception as exc:  # noqa: BLE001 - matches MATLAB's catch-all `catch ME`
            if verbose:
                print(f"[{idx}] MBP ERROR: {exc} (leaving MBP step as-is)")

        try:
            candidate = [dict(phase) for phase in s]
            candidate = detect_bc_cyl_subphases(candidate, **bc_kwargs)
            s = candidate
            if verbose:
                print(f"[{idx}] BC  done ({len(s)} phases)")
        except Exception as exc:  # noqa: BLE001
            if verbose:
                print(f"[{idx}] BC  ERROR: {exc} (leaving BC step as-is)")

        out.append(s)

    return out
