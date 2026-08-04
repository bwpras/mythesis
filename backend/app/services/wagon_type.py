"""Kit -> wagon type mapping, ported verbatim from the finished thesis's
own test_main_binary.ipynb (load_and_prepare_monorail() cell). T3000 is the
wagon type model.csv's labeled reference data comes from; 4909/4575 are
other wagon types used only for cross-type generalization testing.
"""
from __future__ import annotations

WAGON_TYPE_BY_KIT = {
    1: "T3000",
    6: "T3000",
    27: "T3000",
    30: "T3000",
    10: "4909",
    11: "4909",
    18: "4909",
    24: "4909",
    5: "4575",
    32: "4575",
}

# The exact generalization-test kit set from test_main_binary.ipynb's
# `test_data_path`: T3000's held-out kit (Dati30) plus every other-wagon-type
# kit. Dati01/06/27 (T3000, used alongside model.csv during training) are
# deliberately excluded here -- they're not an unbiased generalization test.
GENERALIZATION_TEST_KITS = ["Dati30", "Dati05", "Dati10", "Dati11", "Dati18", "Dati24"]


def wagon_type_for_kit(kit_id: str) -> str:
    kit_num = int("".join(c for c in kit_id if c.isdigit()))
    return WAGON_TYPE_BY_KIT.get(kit_num, "unknown")
