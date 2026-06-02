"""
runner_grudniowy.py — DOROCZNE odświeżenie lasu (osobny workflow, 1 grudnia).

Odpala odswiez_caly_las(): pobiera świeży las z BDL dla wszystkich rewirów
i regionów, ładuje go do tabeli tymczasowej i dopiero po sukcesie podmienia
stary (bezpiecznie — przy błędzie BDL zostaje stary las, nie pustka).

NIE rusza pogody ani hotspotów — to robi codzienny runner.py.
DATABASE_URL bierze z sekretu repozytorium.
"""

import os
import sys
import traceback

import nocny_agent as A


def main():
    if not os.environ.get("DATABASE_URL"):
        print("BŁĄD: brak DATABASE_URL w środowisku (ustaw sekret repozytorium).")
        sys.exit(1)

    print(">>> DOROCZNE odświeżenie lasu (BDL) — start")
    try:
        A.odswiez_caly_las()
        print(">>> odświeżenie OK")
    except Exception:
        print(">>> odświeżenie NIEUDANE:")
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
