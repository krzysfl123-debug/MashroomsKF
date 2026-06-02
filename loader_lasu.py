"""
Loader lasu — Predict Mushrooms PRO
====================================
Jednorazowy / półroczny import geometrii lasu do tabeli forest_stands.
Ten wariant: MAŁY WYCINEK na próbę (okolice Supraśla, RDLP Białystok) —
żeby przejść całą ścieżkę BDL -> baza -> agent -> hotspoty na znanym terenie.

Co robi:
  1. Pobiera wydzielenia z BDL OGC API (kolekcja RDLP_Bialystok_wydzielenia)
     dla zadanego bbox, z PAGINACJĄ (BDL oddaje po ~stronie z linkami 'next').
  2. Bierze tylko drzewostany (area_type = 'D-STAN'); drogi/rzeki/zręby pomija.
  3. Wstawia do forest_stands (geometria jako MultiPolygon 4326).
  4. Tworzy jeden testowy wpis w scan_regions pokrywający ten sam bbox.

Uruchomienie (lokalnie / GitHub Actions):
  DATABASE_URL=postgresql://...  python loader_lasu.py

Zależności: requests, psycopg2-binary, shapely.
Sekret: DATABASE_URL (service-side; omija RLS).
"""

import os
import json
import time

import requests

# --- WYCINEK: Słupsk i okolice ---------------------------------------
# Słupsk leży w zasięgu RDLP Szczecinek (cd '11'); nadleśnictwa Ustka,
# Leśny Dwór, Damnica itd. UWAGA: granice RDLP nie pokrywają się z miastami —
# jeśli loader zwróci 0 obiektów, Słupsk wpadł na sąsiednią dyrekcję:
# zmień wtedy KOLEKCJA na "RDLP_Gdansk_wydzielenia" i RDLP_CD na "15".
KOLEKCJA = "RDLP_Szczecinek_wydzielenia"
BBOX = (16.90, 54.36, 17.20, 54.52)          # ~Słupsk i okolice (lon_min,lat_min,lon_max,lat_max)
REGION_NAME = "Słupsk i okolice"
RDLP_CD = "11"                                # Szczecinek

BDL_BASE = "https://ogcapi.bdl.lasy.gov.pl/collections"


def bdl_url(kolekcja):
    return f"{BDL_BASE}/{kolekcja}/items"


# Wszystkie 17 dyrekcji RDLP w BDL OGC API: (kolekcja, cd, przybliżony bbox zasięgu
# lon_min,lat_min,lon_max,lat_max). Bboxy są zgrubne i NACHODZĄ na siebie — służą
# tylko do USTALENIA KOLEJNOŚCI prób. Faktyczny filtr robi bbox rewiru po stronie
# BDL, więc zapytanie do złej dyrekcji po prostu zwróci 0 i próbujemy dalej.
RDLP_DYREKCJE = [
    ("RDLP_Bialystok_wydzielenia",   "01", (21.5, 52.5, 24.2, 54.4)),
    ("RDLP_Gdansk_wydzielenia",      "15", (17.2, 53.5, 19.8, 54.9)),
    ("RDLP_Katowice_wydzielenia",    "02", (18.0, 49.4, 20.0, 51.2)),
    ("RDLP_Krakow_wydzielenia",      "03", (19.4, 49.2, 21.5, 50.6)),
    ("RDLP_Krosno_wydzielenia",      "04", (21.0, 49.0, 23.0, 50.3)),
    ("RDLP_Lublin_wydzielenia",      "05", (21.6, 50.2, 24.2, 52.3)),
    ("RDLP_Lodz_wydzielenia",        "06", (18.2, 50.8, 20.7, 52.4)),
    ("RDLP_Olsztyn_wydzielenia",     "07", (19.3, 53.0, 22.5, 54.5)),
    ("RDLP_Pila_wydzielenia",        "08", (15.8, 52.6, 17.8, 53.8)),
    ("RDLP_Poznan_wydzielenia",      "09", (16.0, 51.6, 18.4, 53.0)),
    ("RDLP_Radom_wydzielenia",       "10", (19.7, 50.5, 22.0, 51.8)),
    ("RDLP_Szczecin_wydzielenia",    "12", (13.9, 52.5, 15.9, 54.0)),
    ("RDLP_Szczecinek_wydzielenia",  "11", (15.5, 53.4, 17.6, 54.6)),
    ("RDLP_Torun_wydzielenia",       "13", (17.4, 52.4, 19.6, 53.8)),
    ("RDLP_Warszawa_wydzielenia",    "14", (20.0, 51.4, 22.5, 53.2)),
    ("RDLP_Wroclaw_wydzielenia",     "16", (15.2, 50.4, 17.8, 51.6)),
    ("RDLP_Zielona_Gora_wydzielenia","17", (14.4, 51.3, 16.4, 52.7)),
]


def dyrekcje_dla_bbox(bbox):
    """Zwraca listę (kolekcja, cd) posortowaną wg trafności: najpierw dyrekcje,
    których zgrubny zasięg pokrywa środek rewiru, potem najbliższe jako zapas.
    Faktyczny filtr i tak robi bbox po stronie BDL — to tylko kolejność prób."""
    lon_min, lat_min, lon_max, lat_max = bbox
    clat = (lat_min + lat_max) / 2.0
    clon = (lon_min + lon_max) / 2.0

    trafne, reszta = [], []
    for k, cd, (a, b, c, d) in RDLP_DYREKCJE:
        if a <= clon <= c and b <= clat <= d:
            trafne.append((k, cd))
        else:
            mx, my = (a + c) / 2, (b + d) / 2
            reszta.append(((mx - clon) ** 2 + (my - clat) ** 2, k, cd))
    reszta.sort()
    # trafne najpierw, potem 3 najbliższe jako zapas (gdyby rewir leżał na styku dyrekcji)
    return trafne + [(k, cd) for (_, k, cd) in reszta[:3]]


def pobierz_wydzielenia_bbox(bbox, kolekcja=None, page_limit=500, max_stron=40):
    """Pobiera wszystkie wydzielenia w bbox, idąc za linkami 'next' (paginacja).
    kolekcja: nazwa kolekcji BDL (domyślnie globalna KOLEKCJA dla trybu Słupsk)."""
    if kolekcja is None:
        kolekcja = KOLEKCJA
    lon_min, lat_min, lon_max, lat_max = bbox
    params = {
        "bbox": f"{lon_min},{lat_min},{lon_max},{lat_max}",
        "limit": page_limit,
        "f": "json",
    }
    url = bdl_url(kolekcja)
    features = []
    strona = 0
    while url and strona < max_stron:
        for proba in range(3):
            try:
                r = requests.get(url, params=params if strona == 0 else None, timeout=40)
                data = r.json()
                break
            except Exception:
                time.sleep(1.0)
        else:
            print("  ! nie udało się pobrać strony, przerywam paginację")
            break

        batch = data.get("features", [])
        features.extend(batch)
        strona += 1
        print(f"  strona {strona}: +{len(batch)} (łącznie {len(features)})")

        # następna strona: link rel='next' (pełny URL z parametrami)
        url = None
        for link in data.get("links", []):
            if link.get("rel") == "next" and link.get("href"):
                url = link["href"]
                break
    return features


def feature_na_multipolygon(geom):
    """Zwraca shapely MultiPolygon (BDL bywa Polygon lub MultiPolygon)."""
    from shapely.geometry import shape, MultiPolygon
    g = shape(geom)
    if g.geom_type == "Polygon":
        g = MultiPolygon([g])
    elif g.geom_type != "MultiPolygon":
        return None
    return g


def db_conn():
    import psycopg2
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError("Brak DATABASE_URL w środowisku.")
    return psycopg2.connect(url)


def zaladuj(features, conn, rdlp_cd=None):
    """Wstawia drzewostany (D-STAN) do forest_stands. Zwraca (wstawione, pominięte).
    rdlp_cd: kod dyrekcji zapisywany w rekordach (domyślnie globalny RDLP_CD)."""
    if rdlp_cd is None:
        rdlp_cd = RDLP_CD
    from shapely import wkb
    from psycopg2.extras import execute_values

    rows = []
    pominiete = 0
    for f in features:
        props = f.get("properties", {}) or {}
        if (props.get("area_type") or "D-STAN") != "D-STAN":
            pominiete += 1
            continue
        geom = f.get("geometry")
        if not geom:
            continue
        mp = feature_na_multipolygon(geom)
        if mp is None:
            continue

        species = (props.get("species_cd") or "NONE")
        species = str(species).strip().upper() or "NONE"
        try:
            wiek = int(props.get("spec_age")) if props.get("spec_age") is not None else None
        except Exception:
            wiek = None

        # a_year: wyłuskaj sam ROK z nazwy BDL (np. "BDL_01_06_CZARNA_..._2025" -> 2025)
        rok = None
        nazwa = props.get("nazwa") or ""
        for kawalek in str(nazwa).replace("-", "_").split("_"):
            if kawalek.isdigit() and len(kawalek) == 4 and kawalek.startswith("20"):
                rok = int(kawalek)
                break

        rows.append((
            "BDL", rdlp_cd, props.get("adr_for"),
            species, wiek, props.get("area_type"),
            rok,                                        # a_year = sam rok (int) albo None
            wkb.dumps(mp, hex=True, srid=4326),         # geometria -> WKB hex dla PostGIS
        ))

    if not rows:
        print("  (brak drzewostanów D-STAN do wstawienia)")
        return 0, pominiete

    with conn.cursor() as cur:
        execute_values(cur, """
            insert into forest_stands
              (source, rdlp_cd, adr_for, species_cd, spec_age, area_type, a_year, geom)
            values %s
        """, rows, template="(%s,%s,%s,%s,%s,%s,%s, st_geomfromewkb(decode(%s,'hex')))")
    conn.commit()
    return len(rows), pominiete


def utworz_region(conn, bbox, name, rdlp_cd):
    """Tworzy testowy scan_regions = prostokąt bbox (jeśli jeszcze go nie ma)."""
    lon_min, lat_min, lon_max, lat_max = bbox
    with conn.cursor() as cur:
        cur.execute("select id from scan_regions where name = %s", (name,))
        if cur.fetchone():
            print("  region już istnieje — pomijam")
            return
        cur.execute("""
            insert into scan_regions (name, rdlp_cd, geom, active)
            values (%s, %s,
                    st_setsrid(st_makeenvelope(%s,%s,%s,%s), 4326),
                    true)
        """, (name, rdlp_cd, lon_min, lat_min, lon_max, lat_max))
    conn.commit()
    print(f"  region utworzony: {name}")


def zaladuj_obszar(conn, bbox, prog_min=1):
    """ŁADOWANIE NA ŻĄDANIE: pobiera las dla dowolnego bbox (np. rewiru) i wstawia
    do forest_stands. Sam dobiera dyrekcję RDLP — próbuje kolejno najtrafniejszych,
    aż któraś zwróci sensowną liczbę drzewostanów. Zwraca (wstawione, kolekcja) albo (0, None).
    Wywoływana przez nocnego agenta dla rewirów, które jeszcze nie mają lasu."""
    for kolekcja, cd in dyrekcje_dla_bbox(bbox):
        print(f"  [las] próbuję dyrekcji {kolekcja} (cd {cd}) dla bbox {bbox}")
        try:
            feats = pobierz_wydzielenia_bbox(bbox, kolekcja=kolekcja)
        except Exception as e:
            print(f"  [las] błąd pobierania z {kolekcja}: {e}")
            continue
        if len(feats) < prog_min:
            print(f"  [las] {kolekcja}: tylko {len(feats)} obiektów — próbuję dalej")
            continue
        wstawione, pominiete = zaladuj(feats, conn, rdlp_cd=cd)
        if wstawione >= prog_min:
            print(f"  [las] OK: {kolekcja} -> wstawiono {wstawione} drzewostanów")
            return wstawione, kolekcja
        print(f"  [las] {kolekcja}: 0 D-STAN po filtrze — próbuję dalej")
    print(f"  [las] nie znaleziono lasu dla bbox {bbox} w żadnej dyrekcji")
    return 0, None


def main():
    print(f"Pobieram wydzielenia BDL: {KOLEKCJA}  bbox={BBOX}")
    feats = pobierz_wydzielenia_bbox(BBOX)
    print(f"Pobrano {len(feats)} obiektów z BDL.")

    conn = db_conn()
    try:
        wstawione, pominiete = zaladuj(feats, conn)
        print(f"Wstawiono drzewostanów (D-STAN): {wstawione}  | pominięto nie-D-STAN: {pominiete}")
        utworz_region(conn, BBOX, REGION_NAME, RDLP_CD)
        print("GOTOWE. forest_stands napełnione, region testowy utworzony.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
