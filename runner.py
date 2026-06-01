"""
runner.py — punkt wejścia nocnego agenta dla GitHub Actions.

Odpala po kolei:
  1) run_makro()  — skan krajowy (potencjał pogodowy nad całą Polską),
  2) run_scan()   — skan szczegółowy dla zdefiniowanych regionów/rewirów
                    (jeśli forest_stands i scan_regions są napełnione; jeśli
                    puste, po prostu nic nie policzy — to nie błąd).

Każdy skan sam zamyka swój przebieg i sprząta starsze. DATABASE_URL bierze
ze zmiennej środowiskowej (sekret repozytorium) — NIGDY z kodu.
"""

import os
import sys
import traceback

import nocny_agent as A


def main():
    if not os.environ.get("DATABASE_URL"):
        print("BŁĄD: brak DATABASE_URL w środowisku (ustaw sekret repozytorium).")
        sys.exit(1)

    bledy = []

    print(">>> [1/2] Skan krajowy (makro)...")
    try:
        A.run_makro()
        print(">>> makro OK")
    except Exception:
        print(">>> makro NIEUDANE:")
        traceback.print_exc()
        bledy.append("makro")

    print(">>> [2/2] Skan szczegółowy (rewiry/regiony)...")
    try:
        A.run_scan()
        print(">>> detail OK")
    except Exception:
        print(">>> detail NIEUDANE:")
        traceback.print_exc()
        bledy.append("detail")

    if bledy:
        print(f">>> ZAKOŃCZONO Z BŁĘDAMI: {', '.join(bledy)}")
        sys.exit(1)
    print(">>> WSZYSTKO OK")


if __name__ == "__main__":
    main()
