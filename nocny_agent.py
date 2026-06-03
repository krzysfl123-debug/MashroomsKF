"""
Nocny agent — Predict Mushrooms PRO
====================================
Autonomiczny "kombajn" obliczeniowy. Uruchamiany cyklicznie (cron / GitHub Actions).

Przepływ:
  1. Otwórz nowy przebieg (scan_runs, status='running').
  2. Dla każdego aktywnego regionu (scan_regions):
       a. zbuduj grubą siatkę pogodową (~10 km) nad regionem,
       b. dociągnij pogodę NARASTAJĄCO (archive + forecast) i zrób upsert do weather_daily,
       c. wczytaj wydzielenia lasu z forest_stands przecinające region,
       d. dla każdego wydzielenia: odziedzicz pogodę najbliższej komórki,
          policz szanse dla [dziś, +14, +28], zapisz hotspoty > progu.
  3. Zamknij przebieg (status='done') -> aplikacja zacznie go widzieć.

Zależności środowiskowe (NIE są importowane na górze, tylko w funkcjach,
żeby rdzeń modelu dało się testować bez nich):
  - requests          (Open-Meteo)
  - psycopg2-binary    (Postgres / Supabase, przez DATABASE_URL z service_role)

Sekrety (zmienne środowiskowe — NIGDY w kodzie):
  - DATABASE_URL  : postgresql://...  (połączenie z bazą; klucz/hasło service-side)
"""

import math
import os
import datetime as dt
from datetime import timedelta

# =====================================================================
# 1. MODEL — parametry gatunków (tylko to, czego potrzebuje algorytm).
#    Pełne opisy/atlas zostają po stronie aplikacji; agent liczy.
# =====================================================================
PROG_OBECNOSCI = 0.35

# klucz: (t_opt, t_tol, deszcz=(d_start,d_end), deszcz_min, ochlodzenie,
#         mce=range, symbioza=[...], wiek_min, wiek_max)
GATUNKI = {
    "Borowik szlachetny":   dict(t_opt=13.5, t_tol=4.5, deszcz=(15, 5), deszcz_min=20, ochlodzenie=0.30, mce=range(6, 12), symbioza=["SO", "ŚW", "DB", "BK"], wiek_min=40, wiek_max=999),
    "Borowik usiatkowany":  dict(t_opt=20.0, t_tol=4.0, deszcz=(12, 3), deszcz_min=12, ochlodzenie=0.00, mce=range(5, 10), symbioza=["DB", "BK", "GB"], wiek_min=40, wiek_max=999),
    "Borowik ceglastoporowy": dict(t_opt=16.0, t_tol=4.5, deszcz=(13, 3), deszcz_min=15, ochlodzenie=0.10, mce=range(6, 12), symbioza=["ŚW", "JD", "BK", "DB"], wiek_min=30, wiek_max=999),
    "Podgrzybek brunatny":  dict(t_opt=13.0, t_tol=4.0, deszcz=(14, 4), deszcz_min=20, ochlodzenie=0.20, mce=range(8, 12), symbioza=["SO", "ŚW"], wiek_min=30, wiek_max=999),
    "Podgrzybek zajączek":  dict(t_opt=16.0, t_tol=4.0, deszcz=(12, 3), deszcz_min=15, ochlodzenie=0.00, mce=range(6, 11), symbioza=["SO", "DB", "BK", "BRZ"], wiek_min=20, wiek_max=999),
    "Maślak zwyczajny":     dict(t_opt=14.0, t_tol=4.0, deszcz=(10, 2), deszcz_min=12, ochlodzenie=0.10, mce=range(6, 12), symbioza=["SO"], wiek_min=5, wiek_max=40),
    "Maślak sitarz":        dict(t_opt=13.0, t_tol=4.0, deszcz=(10, 2), deszcz_min=12, ochlodzenie=0.10, mce=range(7, 12), symbioza=["SO"], wiek_min=10, wiek_max=60),
    "Koźlarz babka":        dict(t_opt=18.0, t_tol=5.0, deszcz=(10, 2), deszcz_min=12, ochlodzenie=0.00, mce=range(6, 11), symbioza=["BRZ"], wiek_min=10, wiek_max=999),
    "Koźlarz czerwony":     dict(t_opt=18.0, t_tol=5.0, deszcz=(10, 2), deszcz_min=12, ochlodzenie=0.00, mce=range(6, 11), symbioza=["OS"], wiek_min=10, wiek_max=999),
    "Kurka":                dict(t_opt=18.0, t_tol=4.0, deszcz=(20, 3), deszcz_min=30, ochlodzenie=0.00, mce=range(6, 11), symbioza=["SO", "ŚW", "DB", "BK", "BRZ"], wiek_min=20, wiek_max=999),
    "Rydz":                 dict(t_opt=11.0, t_tol=4.0, deszcz=(38, 7), deszcz_min=35, ochlodzenie=0.20, mce=range(8, 12), symbioza=["SO", "ŚW"], wiek_min=10, wiek_max=45),
    "Czubajka kania":       dict(t_opt=18.0, t_tol=4.0, deszcz=(12, 2), deszcz_min=15, ochlodzenie=0.00, mce=range(7, 11), symbioza=["ALL"], wiek_min=0, wiek_max=999),
    "Gołąbek zielonawy":    dict(t_opt=19.0, t_tol=4.0, deszcz=(12, 3), deszcz_min=15, ochlodzenie=0.00, mce=range(6, 10), symbioza=["DB", "BK", "BRZ"], wiek_min=30, wiek_max=999),
    "Gąska zielonka":       dict(t_opt=8.0,  t_tol=4.0, deszcz=(18, 4), deszcz_min=20, ochlodzenie=0.30, mce=range(9, 13), symbioza=["SO"], wiek_min=30, wiek_max=999),
}


def _clip(x, lo, hi):
    return max(lo, min(hi, x))


def skuteczna_woda(weather, target, d_start, d_end):
    """Suma opadu w oknie [target-d_start .. target-d_end] z parowaniem.
    weather: dict {date -> {'t_max','t_min','rain'}}. Parowanie: powyżej 15°C
    każdy dzień ścina zmagazynowaną wodę o (t_max-15)*1.5%, sufit 15%."""
    woda = 0.0
    d = target - timedelta(days=int(d_start))
    end = target - timedelta(days=int(d_end))
    while d <= end:
        rec = weather.get(d)
        if rec:
            woda += rec.get("rain") or 0.0
            t_max = rec.get("t_max")
            if t_max is None:
                t_max = 15.0
            if t_max > 15.0:
                woda *= (1.0 - min((t_max - 15.0) * 0.015, 0.15))
        d += timedelta(days=1)
    return woda


def _buduj_temp_ffill(weather, target):
    """Ciągły szereg średniej temperatury dobowej do daty `target`, z FORWARD-FILL:
    tam, gdzie brak danych (zwłaszcza dla dat poza horyzontem prognozy), trzymamy
    ostatnią znaną wartość (persystencja). Deszczu to NIE dotyczy — opad liczony
    jest wyłącznie z realnych/prognozowanych dni (patrz skuteczna_woda)."""
    znane = {}
    for d, rec in weather.items():
        if rec.get("t_max") is not None and rec.get("t_min") is not None:
            znane[d] = (rec["t_max"] + rec["t_min"]) / 2.0
    if not znane:
        return {}
    seria = {}
    ostatnia = None
    d = min(znane)
    while d <= target:
        if d in znane:
            ostatnia = znane[d]
        seria[d] = ostatnia
        d += timedelta(days=1)
    return seria


def _srednia_okno(temp_ff, target, a, b):
    """Średnia temperatura w oknie [target-a .. target-b] z szeregu ffill."""
    vals = []
    d = target - timedelta(days=int(a))
    end = target - timedelta(days=int(b))
    while d <= end:
        v = temp_ff.get(d)
        if v is not None:
            vals.append(v)
        d += timedelta(days=1)
    return sum(vals) / len(vals) if vals else None


def oblicz_szanse_punkt(weather, target, drzewo, wiek, temp_ff=None):
    """Zwraca listę (gatunek, prob_procent, t_dev) dla punktu o danym drzewostanie.
    Identyczna logika jak w aplikacji Streamlit (Gauss temp x nasycenie wodą
    x sezon x bonus za ochłodzenie), z bramką symbiozy/wieku.
    temp_ff: opcjonalny, gotowy szereg temperatury (gdy liczymy wiele dat dla tej
    samej komórki — np. w skanie makro — budujemy go raz i podajemy tutaj)."""
    if temp_ff is None:
        temp_ff = _buduj_temp_ffill(weather, target)
    t_dev = _srednia_okno(temp_ff, target, 7, 0)
    if t_dev is None:
        return []

    tr = _srednia_okno(temp_ff, target, 5, 0)
    te = _srednia_okno(temp_ff, target, 16, 9)
    chl = _clip((te - tr) / 8.0, 0.0, 1.0) if (tr is not None and te is not None) else 0.0

    miesiac = target.month
    wyniki = []
    for nazwa, p in GATUNKI.items():
        # bramka symbiozy + wieku (identyczna jak w app.py)
        if not ("ALL" in p["symbioza"] or drzewo == "ALL"
                or (drzewo in p["symbioza"] and p["wiek_min"] <= wiek <= p["wiek_max"])):
            continue

        sezon = 1.0 if miesiac in p["mce"] else (
            0.45 if (miesiac + 1) in p["mce"] or (miesiac - 1) in p["mce"] else 0.10)
        woda = skuteczna_woda(weather, target, p["deszcz"][0], p["deszcz"][1])
        ocena_t = math.exp(-((t_dev - p["t_opt"]) / p["t_tol"]) ** 2)
        ocena_w = _clip(woda / p["deszcz_min"], 0.0, 1.0)

        prob = min(ocena_t * ocena_w * sezon * (1.0 + p["ochlodzenie"] * chl), 1.0)
        if prob >= PROG_OBECNOSCI:
            wyniki.append((nazwa, int(round(prob * 100)), round(t_dev, 1)))

    wyniki.sort(key=lambda x: x[1], reverse=True)
    return wyniki


# =====================================================================
# 2. POGODA — Open-Meteo, narastająco (archive + forecast).
# =====================================================================
def cell_key(lat, lon):
    """Komórka grubej siatki ~0,1° (~10 km) — środek dziedziczony przez punkty leśne."""
    return (round(lat, 1), round(lon, 1))


def pobierz_pogode_komorek(cells, dni_wstecz=45, dni_wprzod=15):
    """Pobiera pogodę dla listy komórek (lat,lon). Zwraca:
    {(clat,clon): {date: {'t_max','t_min','rain','kind'}}}.
    'archive' z ERA5, 'forecast' z modelu Open-Meteo (ICON-D2 na pierwsze dni)."""
    import time
    import requests

    dzis = dt.date.today()
    arch_start = (dzis - timedelta(days=dni_wstecz)).isoformat()
    dzis_str = dzis.isoformat()
    fc_start = (dzis - timedelta(days=15)).isoformat()
    # Forecast API sięga max ~16 dni w przód — przycinamy, by nie dostać błędu 400.
    dni_fc = min(int(dni_wprzod), 15)
    fc_end = (dzis + timedelta(days=dni_fc)).isoformat()

    out = {}
    cells = list(cells)

    def fetch(url, params):
        for _ in range(3):
            try:
                return requests.get(url, params=params, timeout=30).json()
            except Exception:
                time.sleep(0.6)
        return {}

    # batch po 50 współrzędnych na zapytanie (limit Open-Meteo)
    for i in range(0, len(cells), 50):
        chunk = cells[i:i + 50]
        wsp = {
            "latitude": ",".join(str(c[0]) for c in chunk),
            "longitude": ",".join(str(c[1]) for c in chunk),
            "timezone": "Europe/Warsaw",
        }
        # UWAGA: archiwum (ERA5) zna 'rain_sum'; prognoza używa 'precipitation_sum'.
        arch = fetch("https://archive-api.open-meteo.com/v1/archive",
                     {**wsp, "daily": "temperature_2m_max,temperature_2m_min,rain_sum",
                      "start_date": arch_start, "end_date": dzis_str})
        fcst = fetch("https://api.open-meteo.com/v1/forecast",
                     {**wsp, "daily": "temperature_2m_max,temperature_2m_min,precipitation_sum",
                      "start_date": fc_start, "end_date": fc_end})
        arch = arch if isinstance(arch, list) else [arch]
        fcst = fcst if isinstance(fcst, list) else [fcst]

        for j, (lat, lon) in enumerate(chunk):
            seria = {}
            # archive (historia) — niżej priorytet niż forecast tam, gdzie się pokrywają
            if j < len(arch) and isinstance(arch[j], dict) and "daily" in arch[j]:
                d = arch[j]["daily"]
                for k, t in enumerate(d["time"]):
                    seria[dt.date.fromisoformat(t)] = {
                        "t_max": d["temperature_2m_max"][k], "t_min": d["temperature_2m_min"][k],
                        "rain": d["rain_sum"][k], "kind": "archive"}
            # forecast — nadpisuje pokrywające się dni (świeższe + sięga w przyszłość)
            if j < len(fcst) and isinstance(fcst[j], dict) and "daily" in fcst[j]:
                d = fcst[j]["daily"]
                # prognoza zwraca opad jako 'precipitation_sum' (nie 'rain_sum')
                opad = d.get("precipitation_sum") or d.get("rain_sum")
                for k, t in enumerate(d["time"]):
                    seria[dt.date.fromisoformat(t)] = {
                        "t_max": d["temperature_2m_max"][k], "t_min": d["temperature_2m_min"][k],
                        "rain": opad[k] if opad else None, "kind": "forecast"}
            out[cell_key(lat, lon)] = seria
    return out


# =====================================================================
# 3. BAZA — Postgres/Supabase (service_role przez DATABASE_URL).
# =====================================================================
def db_conn():
    import psycopg2
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise RuntimeError("Brak DATABASE_URL w środowisku (sekret service-side).")
    return psycopg2.connect(url)


def upsert_weather(conn, weather_map):
    """Zapis pogody narastająco — upsert po (cell_lat,cell_lon,obs_date,kind)."""
    rows = []
    for (clat, clon), seria in weather_map.items():
        for d, rec in seria.items():
            rows.append((clat, clon, d, rec["kind"], rec["t_max"], rec["t_min"], rec["rain"]))
    if not rows:
        return
    from psycopg2.extras import execute_values
    with conn.cursor() as cur:
        execute_values(cur, """
            insert into weather_daily (cell_lat,cell_lon,obs_date,kind,t_max,t_min,rain_sum)
            values %s
            on conflict (cell_lat,cell_lon,obs_date,kind) do update
              set t_max=excluded.t_max, t_min=excluded.t_min,
                  rain_sum=excluded.rain_sum, fetched_at=now()
        """, rows)
    conn.commit()


def aktywne_regiony(conn):
    with conn.cursor() as cur:
        cur.execute("""select id, name,
                              st_ymin(geom::box2d) as lat_min, st_ymax(geom::box2d) as lat_max,
                              st_xmin(geom::box2d) as lon_min, st_xmax(geom::box2d) as lon_max
                       from scan_regions where active = true""")
        cols = [c[0] for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]


def wydzielenia_regionu(conn, region_id):
    """Wydzielenia (D-STAN) przecinające region, z reprezentatywnym punktem (centroid)."""
    with conn.cursor() as cur:
        cur.execute("""
            select fs.species_cd, fs.spec_age,
                   st_y(st_centroid(fs.geom)) as lat,
                   st_x(st_centroid(fs.geom)) as lon
            from forest_stands fs
            join scan_regions sr on sr.id = %s
            where st_intersects(fs.geom, sr.geom)
              and coalesce(fs.area_type,'D-STAN') = 'D-STAN'
        """, (region_id,))
        out = []
        for species_cd, spec_age, lat, lon in cur.fetchall():
            out.append({
                "drzewo": (species_cd or "NONE").strip().upper(),
                "wiek": int(spec_age) if spec_age is not None else 50,
                "lat": float(lat), "lon": float(lon),
            })
        return out


def aktywne_rewiry(conn):
    """Rewiry założone przez użytkowników (z aplikacji). Zwraca id, nazwę i bbox."""
    with conn.cursor() as cur:
        cur.execute("""select id, name,
                              st_ymin(geom::box2d) as lat_min, st_ymax(geom::box2d) as lat_max,
                              st_xmin(geom::box2d) as lon_min, st_xmax(geom::box2d) as lon_max
                       from rewiry where active = true""")
        cols = [c[0] for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]


def rewir_ma_las(conn, rewir_id):
    """Czy w forest_stands są drzewostany przecinające ten rewir?"""
    with conn.cursor() as cur:
        cur.execute("""
            select exists(
              select 1 from forest_stands fs
              join rewiry r on r.id = %s
              where st_intersects(fs.geom, r.geom)
            )
        """, (rewir_id,))
        return bool(cur.fetchone()[0])


def wydzielenia_rewiru(conn, rewir_id):
    """Wydzielenia (D-STAN) przecinające rewir, z punktem reprezentatywnym (centroid)."""
    with conn.cursor() as cur:
        cur.execute("""
            select fs.species_cd, fs.spec_age,
                   st_y(st_centroid(fs.geom)) as lat,
                   st_x(st_centroid(fs.geom)) as lon
            from forest_stands fs
            join rewiry r on r.id = %s
            where st_intersects(fs.geom, r.geom)
              and coalesce(fs.area_type,'D-STAN') = 'D-STAN'
        """, (rewir_id,))
        out = []
        for species_cd, spec_age, lat, lon in cur.fetchall():
            out.append({
                "drzewo": (species_cd or "NONE").strip().upper(),
                "wiek": int(spec_age) if spec_age is not None else 50,
                "lat": float(lat), "lon": float(lon),
            })
        return out


def dociagnij_las_dla_rewiru(conn, rewir):
    """WARIANT 1: jeśli rewir nie ma jeszcze lasu, dociąga go z BDL raz (auto-dyrekcja).
    Zwraca True, jeśli po operacji rewir ma las."""
    if rewir_ma_las(conn, rewir["id"]):
        return True
    print(f"[rewir {rewir['id']} '{rewir.get('name')}'] brak lasu — dociągam z BDL")
    import loader_lasu as LL
    bbox = (rewir["lon_min"], rewir["lat_min"], rewir["lon_max"], rewir["lat_max"])
    wstawione, kolekcja = LL.zaladuj_obszar(conn, bbox)
    if wstawione > 0:
        print(f"[rewir {rewir['id']}] dociągnięto las: {wstawione} drzewostanów ({kolekcja})")
        return True
    print(f"[rewir {rewir['id']}] nie udało się dociągnąć lasu")
    return False


def nowy_przebieg(conn, kind="detail"):
    with conn.cursor() as cur:
        cur.execute("insert into scan_runs (status, kind) values ('running', %s) returning id", (kind,))
        rid = cur.fetchone()[0]
    conn.commit()
    return rid


def sprzataj_stare(conn, kind):
    """Po udanym przebiegu kasuje wszystkie STARSZE przebiegi tego samego rodzaju
    (hotspoty/potencjał znikają kaskadowo). W bazie zostaje tylko najnowszy komplet."""
    with conn.cursor() as cur:
        cur.execute("""
            delete from scan_runs
            where kind = %s
              and id <> (select max(id) from scan_runs where kind = %s and status = 'done')
        """, (kind, kind))
    conn.commit()


def zamknij_przebieg(conn, run_id, status="done", note=None):
    with conn.cursor() as cur:
        cur.execute("update scan_runs set status=%s, finished_at=now(), note=%s where id=%s",
                    (status, note, run_id))
    conn.commit()


def zapisz_hotspoty(conn, rows):
    if not rows:
        return
    from psycopg2.extras import execute_values
    with conn.cursor() as cur:
        execute_values(cur, """
            insert into hotspots
              (run_id, valid_for_date, lat, lon, species, prob, t_dev, drzewo, wiek, region_id)
            values %s
        """, rows)
    conn.commit()


def zapisz_potential(conn, rows):
    """Zapis krajowej siatki potencjału (cell_lat, cell_lon, score, top_species)."""
    if not rows:
        return
    from psycopg2.extras import execute_values
    with conn.cursor() as cur:
        execute_values(cur, """
            insert into potential_grid
              (run_id, valid_for_date, cell_lat, cell_lon, score, top_species)
            values %s
        """, rows)
    conn.commit()


# =====================================================================
# 4. LEJEK — główne pętle agenta.
# =====================================================================
def daty_docelowe(horyzont=tuple(range(0, 29))):
    dzis = dt.date.today()
    return [dzis + timedelta(days=h) for h in horyzont]


# Prostokąt obejmujący Polskę (lon_min, lat_min, lon_max, lat_max).
POLSKA_BBOX = (14.0, 49.0, 24.2, 55.0)

# Granica Polski jako wielokąt (lon, lat) — obrys po punktach granicznych, z lekkim
# zapasem na zewnątrz, by nie uciąć kraju przy brzegu/granicy. Pokrywa narożniki
# (Suwałki, Bieszczady, Hel, Kłodzko, Szczecin); odcina Bałtyk i zagranicę.
# Sprawdzenie przynależności: ray casting (punkt_w_wielokacie).
POLSKA_POLY = [
    (14.12, 53.91), (14.27, 53.75), (14.20, 54.13), (15.20, 54.20),
    (16.50, 54.58), (17.50, 54.80), (18.40, 54.84), (19.30, 54.45),
    (19.65, 54.45), (22.80, 54.36), (23.00, 54.15), (23.55, 53.95),
    (23.95, 52.95), (23.65, 52.32), (23.92, 52.10), (24.15, 50.85),
    (23.70, 50.40), (22.95, 49.55), (22.55, 49.08), (21.50, 49.40),
    (20.10, 49.18), (19.50, 49.40), (18.85, 49.50), (18.05, 49.92),
    (17.40, 50.20), (16.60, 50.10), (16.20, 50.65), (15.00, 50.78),
    (14.60, 51.55), (14.75, 52.07), (14.12, 52.85), (14.12, 53.91),
]


def w_polsce(lat, lon):
    """Czy punkt leży w granicach Polski (ray casting względem POLSKA_POLY)."""
    poly = POLSKA_POLY
    n = len(poly)
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if ((yi > lat) != (yj > lat)) and (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def run_makro(grid_step=0.2, horyzont=tuple(range(0, 29))):
    """SKAN KRAJOWY — tylko pogoda, gruba siatka nad całą Polską (jak dawne 'makro').
    Dla każdej komórki liczy potencjał = najwyższa szansa wśród gatunków przy
    drzewostanie 'ALL' (czyli sam sygnał pogodowy). Wynik -> potential_grid.
    To podstawa dla frontu: gdzie w kraju jest potencjał -> tam zakładasz rewir."""
    conn = db_conn()
    run_id = nowy_przebieg(conn, kind="makro")
    try:
        cele = daty_docelowe(horyzont)
        lon_min, lat_min, lon_max, lat_max = POLSKA_BBOX

        cells = []
        lat = lat_min
        while lat <= lat_max:
            lon = lon_min
            while lon <= lon_max:
                if w_polsce(round(lat, 2), round(lon, 2)):
                    cells.append((round(lat, 2), round(lon, 2)))
                lon = round(lon + grid_step, 2)
            lat = round(lat + grid_step, 2)
        print(f"[makro] komórek w masce Polski: {len(cells)}")

        weather_map = pobierz_pogode_komorek(cells)
        upsert_weather(conn, weather_map)
        print(f"[makro] pobrano pogodę dla {len(weather_map)} komórek")

        pot_rows = []
        for (clat, clon), seria in weather_map.items():
            if not seria:
                continue
            # temp_ff budujemy RAZ na komórkę (do najdalszej daty), reużywamy dla wszystkich dni
            temp_ff = _buduj_temp_ffill(seria, max(cele))
            for target in cele:
                wyniki = oblicz_szanse_punkt(seria, target, "ALL", 50, temp_ff=temp_ff)
                if wyniki:
                    top_nazwa, top_prob, _ = wyniki[0]
                    pot_rows.append((run_id, target, clat, clon, top_prob, top_nazwa))
        zapisz_potential(conn, pot_rows)
        print(f"[makro] zapisano {len(pot_rows)} rekordów potencjału")

        zamknij_przebieg(conn, run_id, "done")
        sprzataj_stare(conn, "makro")
    except Exception as e:
        zamknij_przebieg(conn, run_id, "failed", str(e)[:500])
        raise
    finally:
        conn.close()


def _policz_obszar(conn, run_id, cele, stands, obszar_id):
    """Liczy hotspoty dla listy wydzieleń (stands) danego obszaru i zapisuje je.
    Pogodę pobiera dla grubej siatki pokrywającej te wydzielenia."""
    if not stands:
        return 0
    # siatka pogodowa ~0,1° pokrywająca wszystkie wydzielenia obszaru
    cells = sorted({cell_key(s["lat"], s["lon"]) for s in stands})
    weather_map = pobierz_pogode_komorek(cells)
    upsert_weather(conn, weather_map)

    hot_rows = []
    temp_cache = {}
    for s in stands:
        klucz = cell_key(s["lat"], s["lon"])
        seria = weather_map.get(klucz, {})
        if not seria:
            continue
        if klucz not in temp_cache:
            temp_cache[klucz] = _buduj_temp_ffill(seria, max(cele))
        tff = temp_cache[klucz]
        for target in cele:
            for nazwa, prob, t_dev in oblicz_szanse_punkt(
                    seria, target, s["drzewo"], s["wiek"], temp_ff=tff):
                hot_rows.append((run_id, target, s["lat"], s["lon"],
                                 nazwa, prob, t_dev, s["drzewo"], s["wiek"], obszar_id))
    zapisz_hotspoty(conn, hot_rows)
    return len(hot_rows)


def run_scan(horyzont=tuple(range(0, 29))):
    """SKAN SZCZEGÓŁOWY — dla regionów (scan_regions) ORAZ rewirów użytkowników
    (rewiry): las (BDL) + pogoda -> prognoza wzrostu per wydzielenie, dzień po dniu.
    WARIANT 1: jeśli rewir nie ma jeszcze lasu, agent dociąga go raz z BDL."""
    conn = db_conn()
    run_id = nowy_przebieg(conn, kind="detail")
    try:
        cele = daty_docelowe(horyzont)

        # a) predefiniowane regiony (np. Słupsk z loadera)
        for reg in aktywne_regiony(conn):
            stands = wydzielenia_regionu(conn, reg["id"])
            n = _policz_obszar(conn, run_id, cele, stands, reg["id"])
            print(f"[region {reg['id']} '{reg.get('name')}'] hotspotów: {n}")

        # b) rewiry użytkowników — z automatycznym dociąganiem lasu (wariant 1)
        for rewir in aktywne_rewiry(conn):
            if not dociagnij_las_dla_rewiru(conn, rewir):
                continue  # nie udało się zdobyć lasu — pomijamy, spróbujemy następnej nocy
            stands = wydzielenia_rewiru(conn, rewir["id"])
            n = _policz_obszar(conn, run_id, cele, stands, rewir["id"])
            print(f"[rewir {rewir['id']} '{rewir.get('name')}'] hotspotów: {n}")

        zamknij_przebieg(conn, run_id, "done")
        sprzataj_stare(conn, "detail")
    except Exception as e:
        zamknij_przebieg(conn, run_id, "failed", str(e)[:500])
        raise
    finally:
        conn.close()


def odswiez_caly_las():
    """DOROCZNE ODŚWIEŻENIE (osobny workflow, np. 1 grudnia): pobiera świeży las
    z BDL dla wszystkich rewirów i regionów, po czym podmienia stary.
    BEZPIECZNIE: najpierw ładuje nowy las do TABELI TYMCZASOWEJ, a stary kasuje
    dopiero, gdy nowy się udał — żeby nie zostać z pustą bazą przy błędzie BDL."""
    import loader_lasu as LL
    conn = db_conn()
    try:
        # zbierz wszystkie obszary do odświeżenia (rewiry + regiony) jako bboxy
        obszary = []
        for r in aktywne_rewiry(conn):
            obszary.append(("rewir", r["id"], r.get("name"),
                            (r["lon_min"], r["lat_min"], r["lon_max"], r["lat_max"])))
        for reg in aktywne_regiony(conn):
            obszary.append(("region", reg["id"], reg.get("name"),
                            (reg["lon_min"], reg["lat_min"], reg["lon_max"], reg["lat_max"])))

        if not obszary:
            print("[odswiez] brak rewirów/regionów — nic do odświeżenia")
            return

        print(f"[odswiez] obszarów do odświeżenia: {len(obszary)}")

        # 1) załaduj świeży las do tabeli tymczasowej (klon struktury forest_stands)
        with conn.cursor() as cur:
            cur.execute("drop table if exists forest_stands_new")
            cur.execute("create table forest_stands_new (like forest_stands including all)")
        conn.commit()

        # przekieruj zapis loadera na tabelę tymczasową
        suma = 0
        for typ, oid, nazwa, bbox in obszary:
            print(f"[odswiez] {typ} {oid} '{nazwa}' {bbox}")
            wstawione, kolekcja = LL.zaladuj_obszar(conn, bbox, prog_min=1, tabela="forest_stands_new")
            suma += wstawione
            print(f"[odswiez]   -> {wstawione} drzewostanów ({kolekcja})")

        if suma == 0:
            print("[odswiez] UWAGA: nowy las pusty (0) — NIE kasuję starego, przerywam")
            with conn.cursor() as cur:
                cur.execute("drop table if exists forest_stands_new")
            conn.commit()
            return

        # 2) podmiana atomowa: stary -> kosz, nowy -> forest_stands
        with conn.cursor() as cur:
            cur.execute("drop table if exists forest_stands_old")
            cur.execute("alter table forest_stands rename to forest_stands_old")
            cur.execute("alter table forest_stands_new rename to forest_stands")
            cur.execute("drop table if exists forest_stands_old")
        conn.commit()
        print(f"[odswiez] GOTOWE: podmieniono las, łącznie {suma} drzewostanów")
    finally:
        conn.close()


if __name__ == "__main__":
    run_makro()
    run_scan()
