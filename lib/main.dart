import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'atlas.dart';

// =====================================================================
// DANE DOSTĘPOWE DO SUPABASE
// URL i klucz "anon" (publiczny) — można je wbić w aplikację, są jawne z
// założenia. RLS w bazie pilnuje, że tym kluczem da się tylko czytać
// gotowe dane i wywołać dodaj_rewir. NIGDY nie wklejaj tu service_role!
// Jeśli init zgłosi błąd klucza — weź "anon public" z Supabase:
//   Project Settings -> API -> Project API keys -> anon public.
// =====================================================================
const String kSupabaseUrl = 'https://jsricmfcnygsphnzhqtr.supabase.co';
const String kSupabaseAnon = 'sb_publishable_PGSV8ZZJ6ZwKleFZjpltkQ_FB0GmYzS';

// 14 gatunków grzybów (zgodne z modelem agenta) — do filtra.
const List<String> kGatunki = [
  'Borowik szlachetny', 'Borowik usiatkowany', 'Borowik ceglastoporowy',
  'Podgrzybek brunatny', 'Podgrzybek zajączek', 'Maślak zwyczajny',
  'Maślak sitarz', 'Koźlarz babka', 'Koźlarz czerwony', 'Kurka',
  'Rydz', 'Czubajka kania', 'Gołąbek zielonawy', 'Gąska zielonka',
];

// Rodzaje lasu: kod BDL -> polska nazwa (do filtra). Wszystkie gatunki z bazy.
const Map<String, String> kLasy = {
  // iglaste
  'SO': 'Sosna', 'ŚW': 'Świerk', 'MD': 'Modrzew', 'DG': 'Daglezja', 'CIS': 'Cis',
  // liściaste — dęby
  'DB': 'Dąb', 'DB.S': 'Dąb szypułkowy', 'DB.B': 'Dąb bezszypułkowy',
  'DB.C': 'Dąb czerwony',
  // liściaste — pozostałe
  'BK': 'Buk', 'JS': 'Jesion', 'KL': 'Klon', 'JW': 'Jawor',
  'BRZ': 'Brzoza', 'LP': 'Lipa', 'AK': 'Akacja', 'TP': 'Topola',
  'GB': 'Grab', 'OS': 'Osika', 'OL': 'Olcha', 'OL.S': 'Olcha szara', 'WZ': 'Wiąz',
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: kSupabaseUrl, anonKey: kSupabaseAnon);
  // Android 15+ wymusza edge-to-edge — nie można się wypisać.
  // Włączamy świadomie i obsługujemy insets sami (viewPaddingOf niżej).
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    statusBarColor: Colors.transparent,
  ));
  runApp(const GrzybyApp());
}

final supabase = Supabase.instance.client;

/// Bezpieczne parsowanie liczby — kolumny PostGIS typu numeric potrafią
/// wracać jako STRING (PostgREST chroni precyzję), więc nie rzutujemy na żywca.
double _toD(dynamic v) {
  if (v == null) return 0.0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0.0;
}

int _toI(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

class GrzybyApp extends StatelessWidget {
  const GrzybyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Predict Mushrooms PRO',
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: const MapaEkran(),
    );
  }
}

class MapaEkran extends StatefulWidget {
  const MapaEkran({super.key});
  @override
  State<MapaEkran> createState() => _MapaEkranState();
}

class _MapaEkranState extends State<MapaEkran> {
  final MapController _map = MapController();

  bool _szukam = false; // trwa wyszukiwanie miejscowości
  final _szukajCtrl = TextEditingController();
  int _dzien = 0; // przesunięcie 0..28 dni od dziś
  bool _prognoza = false; // false=tylko historia (suwak 14 dni), true=forecast (28 dni)
  bool _laduje = false;
  String? _info;

  // warstwy danych
  List<_Pkt> _potencjal = []; // krajowa siatka (makro)
  List<_Pkt> _hotspoty = []; // szczegółowe (rewir)
  List<_Rewir> _rewiry = []; // założone rewiry (id, nazwa, środek)
  List<_Wydzielenie> _las = []; // wielokąty lasu (tylko duży zoom)
  bool _pokazLas = false; // przełącznik warstwy lasu (jak poprzednio)
  bool _trybRewiru = false; // gdy włączony, kliknięcie w mapę zakłada rewir

  // --- FILTRY WYŚWIETLANIA (panel boczny) ---
  double _prog = 50;                 // próg prawdopodobieństwa % (dolny)
  double _progMax = 100;             // górna granica % (dla zakresów)
  final Set<String> _fGatunki = {};  // wybrane gatunki grzybów (puste = wszystkie)
  final Set<String> _fLasy = {};     // wybrane rodzaje lasu (puste = wszystkie)
  RangeValues _fWiek = const RangeValues(0, 150); // wiek lasu od-do

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _odswiezWszystko());
  }

  String get _dataISO {
    final d = DateTime.now().add(Duration(days: _dzien));
    String dwa(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${dwa(d.month)}-${dwa(d.day)}';
  }

  Future<void> _odswiezWszystko() async {
    setState(() {
      _laduje = true;
      _info = null;
    });
    try {
      await Future.wait([_wczytajPotencjal(), _wczytajRewiry()]);
      await _wczytajHotspoty(); // wokół aktualnego środka mapy
    } catch (e) {
      _info = 'Błąd pobierania: $e';
    } finally {
      if (mounted) setState(() => _laduje = false);
    }
  }

  Future<void> _wczytajPotencjal() async {
    final res = await supabase.rpc('potential_latest', params: {'in_date': _dataISO});
    final lista = (res as List?) ?? [];
    _potencjal = lista.map((r) {
      final m = r as Map<String, dynamic>;
      return _Pkt(
        LatLng(_toD(m['cell_lat']), _toD(m['cell_lon'])),
        _toI(m['score']),
        (m['top_species'] ?? '').toString(),
      );
    }).toList();
  }

  Future<void> _wczytajHotspoty() async {
    // Bierzemy WIDOCZNY prostokąt mapy (nie promień) — szybkie i tylko to, co widać.
    final b = _map.camera.visibleBounds;
    // Rozmiar kratki siatki zależny od zoomu: bliżej = drobniej = więcej szczegółu.
    final z = _map.camera.zoom;
    final grid = _siatkaDlaZoomu(z);
    final res = await supabase.rpc('hotspots_bbox', params: {
      'in_lat_min': b.south,
      'in_lat_max': b.north,
      'in_lon_min': b.west,
      'in_lon_max': b.east,
      'in_date': _dataISO,
      'in_min_prob': _prog.round(),
      'in_grid': grid,
      'in_limit': 1500,
      'in_species': _fGatunki.isEmpty ? null : _fGatunki.toList(),
      'in_drzewo': _fLasy.isEmpty ? null : _fLasy.toList(),
      'in_wiek_min': _fWiek.start.round(),
      'in_wiek_max': _fWiek.end.round(),
      'in_tryb': _prognoza ? 'forecast' : 'historia',
    });
    final lista = (res as List?) ?? [];
    _hotspoty = lista.map((r) {
      final m = r as Map<String, dynamic>;
      return _Pkt(
        LatLng(_toD(m['lat']), _toD(m['lon'])),
        _toI(m['prob']),
        (m['species'] ?? '').toString(),
      );
    }).where((p) => p.score <= _progMax.round()).toList();
  }

  /// Rozmiar kratki (w stopniach) dobierany do zoomu mapy.
  /// Mały zoom (cała Polska) -> duża kratka; duży zoom (las) -> drobna.
  double _siatkaDlaZoomu(double z) {
    if (z >= 13) return 0.002;   // ~200 m — pojedyncze wydzielenia
    if (z >= 11) return 0.005;   // ~500 m
    if (z >= 9) return 0.01;     // ~1 km
    if (z >= 7) return 0.02;     // ~2 km
    return 0.05;                 // mocno oddalone
  }

  // Warstwa lasu aktywna dopiero od tego zoomu (skala chodzenia, kilka km).
  static const double _zoomLasMin = 11.5;
  // Poniżej tego zoomu pokazujemy makro (krajowy potencjał); powyżej — hotspoty.
  static const double _zoomMikroMin = 9.0;
  double _zoom = 6.2; // aktualny zoom mapy (do przełączania warstw)

  Future<void> _wczytajLas() async {
    // tylko przy dużym zbliżeniu i gdy włączone
    if (!_pokazLas || _map.camera.zoom < _zoomLasMin) {
      _las = [];
      return;
    }
    final b = _map.camera.visibleBounds;
    final res = await supabase.rpc('las_bbox', params: {
      'in_lat_min': b.south,
      'in_lat_max': b.north,
      'in_lon_min': b.west,
      'in_lon_max': b.east,
      'in_limit': 1200,
    });
    final lista = (res as List?) ?? [];
    final out = <_Wydzielenie>[];
    for (final r in lista) {
      final m = r as Map<String, dynamic>;
      final rings = _geoJsonNaPolygony(m['geojson']);
      if (rings.isEmpty) continue;
      out.add(_Wydzielenie(
        rings,
        (m['species_cd'] ?? 'NONE').toString(),
        _toI(m['spec_age']),
      ));
    }
    _las = out;
  }

  /// Parsuje GeoJSON (Polygon / MultiPolygon) na listę pierścieni (zewnętrznych).
  List<List<LatLng>> _geoJsonNaPolygony(dynamic geojsonStr) {
    final out = <List<LatLng>>[];
    try {
      final g = jsonDecode(geojsonStr.toString());
      final typ = g['type'];
      final coords = g['coordinates'];
      if (typ == 'Polygon') {
        out.add(_ring(coords[0]));
      } else if (typ == 'MultiPolygon') {
        for (final poly in coords) {
          out.add(_ring(poly[0])); // pierścień zewnętrzny każdego polygonu
        }
      }
    } catch (_) {}
    return out;
  }

  List<LatLng> _ring(dynamic ring) {
    final pts = <LatLng>[];
    for (final c in ring) {
      pts.add(LatLng(_toD(c[1]), _toD(c[0]))); // GeoJSON = [lon, lat]
    }
    return pts;
  }

  /// Kolor wydzielenia: barwa wg gatunku (zieleń–brąz), jasność wg wieku.
  /// Iglaste → odcienie zieleni (hue 82–168).
  /// Liściaste → odcienie brązu, złota, żółci (hue 8–108).
  /// Wiek 0→120 lat: lightness 0.78→0.30 (młodnik jasny, starodrzew ciemny).
  Color _kolorWydzielenia(String sp, int wiek) {
    double hue, sat;
    switch (sp.toUpperCase()) {
      // ── IGLASTE ─────────────────────────────────────────
      case 'SO':              hue = 115; sat = 0.55; break; // Sosna — zieleń
      case 'ŚW': case 'SW':  hue = 155; sat = 0.58; break; // Świerk — teal-zielony
      case 'MD':              hue = 85;  sat = 0.55; break; // Modrzew — żółtozielony
      case 'DG':              hue = 138; sat = 0.52; break; // Daglezja — głęboka zieleń
      case 'CIS':             hue = 168; sat = 0.48; break; // Cis — ciemny teal
      // ── LIŚCIASTE: dęby ─────────────────────────────────
      case 'DB':              hue = 18;  sat = 0.62; break; // Dąb — brązowy
      case 'DB.S':            hue = 18;  sat = 0.62; break; // Dąb szypułkowy
      case 'DB.B':            hue = 16;  sat = 0.60; break; // Dąb bezszypułkowy
      case 'DB.C':            hue = 8;   sat = 0.68; break; // Dąb czerwony — rudawy brąz
      // ── LIŚCIASTE: ciepłe brązy i złota ─────────────────
      case 'KL':              hue = 22;  sat = 0.70; break; // Klon — pomarańczowy
      case 'BK':              hue = 26;  sat = 0.65; break; // Buk — pomarańczowo-brązowy
      case 'JS':              hue = 32;  sat = 0.58; break; // Jesion — ciepły brąz
      case 'JW':              hue = 38;  sat = 0.55; break; // Jawor — bursztynowy
      case 'WZ':              hue = 41;  sat = 0.58; break; // Wiąz — złoto-brązowy
      case 'BRZ':             hue = 45;  sat = 0.72; break; // Brzoza — złoty
      case 'LP':              hue = 52;  sat = 0.68; break; // Lipa — złoty żółty
      case 'AK':              hue = 58;  sat = 0.62; break; // Akacja — żółtozielony
      // ── LIŚCIASTE: żółcienie i oliwki ───────────────────
      case 'TP':              hue = 65;  sat = 0.55; break; // Topola — żółtozielony
      case 'GB':              hue = 72;  sat = 0.50; break; // Grab — oliwkożółty
      case 'OS':              hue = 78;  sat = 0.55; break; // Osika — limonkowa zieleń
      case 'OL':              hue = 105; sat = 0.45; break; // Olcha — oliwkowa zieleń
      case 'OL.S':            hue = 108; sat = 0.42; break; // Olcha szara — szaro-oliwkowy
      // ── pozostałe/nieznane ──────────────────────────────
      default:                hue = 90;  sat = 0.28; break; // szarozielony
    }
    // wiek 0→120 lat: lightness 0.78→0.30
    final lightness = 0.78 - (wiek.clamp(0, 120) / 120.0) * 0.48;
    return HSLColor.fromAHSL(1.0, hue, sat, lightness).toColor();
  }

  /// Kolor reprezentatywny gatunku (wiek 50 lat) — do legendy i dymka.
  Color _kolorGatunku(String sp) => _kolorWydzielenia(sp, 50);

  Future<void> _wczytajRewiry() async {
    // używamy RPC lista_rewirow — zwraca id, nazwę i gotowy środek
    try {
      final res = await supabase.rpc('lista_rewirow');
      _rewiry = ((res as List?) ?? []).map((r) {
        final m = r as Map<String, dynamic>;
        return _Rewir(_toI(m['id']), (m['name'] ?? 'Rewir').toString(),
            LatLng(_toD(m['lat']), _toD(m['lon'])));
      }).toList();
    } catch (_) {
      _rewiry = [];
    }
  }


  Color _kolor(int score) {
    if (score >= 85) return const Color(0xFF1B5E20);
    if (score >= 70) return const Color(0xFF388E3C);
    if (score >= 55) return const Color(0xFF66BB6A);
    if (score >= 45) return const Color(0xFFC0CA33);
    return const Color(0xFFFFB300);
  }

  /// Skala kolorów DLA HOTSPOTÓW — rozciągnięta na realny zakres szans (≈30–100%),
  /// żeby słabe (30–45%) i mocne (80%+) wyraźnie się różniły barwą.
  Color _kolorHot(int score) {
    if (score >= 85) return const Color(0xFF1B5E20); // ciemna zieleń — pewniak
    if (score >= 75) return const Color(0xFF43A047); // zieleń
    if (score >= 65) return const Color(0xFF9CCC65); // jasna zieleń
    if (score >= 55) return const Color(0xFFFDD835); // żółty
    if (score >= 45) return const Color(0xFFFB8C00); // pomarańcz
    if (score >= 38) return const Color(0xFFE53935); // czerwony
    return const Color(0xFFB71C1C);                  // ciemnoczerwony — słabo
  }

  // =====================================================================
  // KLIK W LAS — hit-testing polygonów (ray-casting, ten sam alg. co agent)
  // =====================================================================

  /// Zwraca wydzielenie lasu, w obrębie którego leży kliknięty punkt (lub null).
  _Wydzielenie? _znajdzWydzielenie(LatLng punkt) {
    for (final w in _las) {
      for (final ring in w.pierscienie) {
        if (_punktWPolygonie(punkt, ring)) return w;
      }
    }
    return null;
  }

  /// Ray-casting: czy punkt (lat/lon) leży wewnątrz wielokąta?
  bool _punktWPolygonie(LatLng p, List<LatLng> poly) {
    bool inside = false;
    int j = poly.length - 1;
    for (int i = 0; i < poly.length; i++) {
      final yi = poly[i].latitude;
      final yj = poly[j].latitude;
      final xi = poly[i].longitude;
      final xj = poly[j].longitude;
      if ((yi > p.latitude) != (yj > p.latitude) &&
          p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
      j = i;
    }
    return inside;
  }

  Future<void> _zapytajORewir(LatLng p) async {
    final nazwaCtrl = TextEditingController(text: 'Mój rewir');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Założyć rewir tutaj?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Środek: ${p.latitude.toStringAsFixed(4)}, '
                '${p.longitude.toStringAsFixed(4)}'),
            const SizedBox(height: 12),
            TextField(
              controller: nazwaCtrl,
              decoration: const InputDecoration(labelText: 'Nazwa rewiru'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Załóż')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await supabase.rpc('dodaj_rewir', params: {
        'in_name': nazwaCtrl.text,
        'in_lat': p.latitude,
        'in_lon': p.longitude,
        'in_promien_km': 5,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rewir założony. Hotspoty pojawią się po nocnym skanie.')),
        );
      }
      await _wczytajRewiry();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nie udało się: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🍄 Predict Mushrooms PRO'),
        actions: [
          IconButton(
            tooltip: 'Atlas grzybów',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AtlasScreen())),
            icon: const Icon(Icons.menu_book),
          ),
          Builder(
            builder: (ctx) => IconButton(
              tooltip: 'Filtry',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
              icon: const Icon(Icons.tune),
            ),
          ),
          IconButton(
            tooltip: 'Odśwież',
            onPressed: _laduje ? null : _odswiezWszystko,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      endDrawer: _panelFiltrow(),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: const LatLng(52.0, 19.4), // środek Polski
              initialZoom: 6.2,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom |
                    InteractiveFlag.drag |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.flingAnimation |
                    InteractiveFlag.scrollWheelZoom,
              ),
              onTap: (tapPos, latlng) {
                if (_trybRewiru) {
                  _zapytajORewir(latlng);
                  setState(() => _trybRewiru = false);
                  return;
                }
                // Klik w wydzielenie lasu (gdy las widoczny, a w tym miejscu
                // nie ma grzybka ani kółka — te mają własne GestureDetektory
                // i pochłaniają tap, więc onTap tutaj nie dosięgnie).
                if (_pokazLas && _las.isNotEmpty) {
                  final w = _znajdzWydzielenie(latlng);
                  if (w != null) _pokazLasInfo(w, latlng);
                }
              },
              onPositionChanged: (camera, hasGesture) {
                if ((camera.zoom - _zoom).abs() > 0.3) {
                  setState(() => _zoom = camera.zoom);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'pl.grzyby.app',
                maxZoom: 19,
              ),
              // warstwa LASU (wielokąty wydzieleń) — tylko duży zoom, kolor wg gatunku.
              // Kliknięcie w dowolne miejsce polygonu -> _pokazLasInfo (via onTap wyżej).
              if (_pokazLas)
                PolygonLayer(
                  polygons: [
                    for (final w in _las)
                      for (final ring in w.pierscienie)
                        Polygon(
                          points: ring,
                          color: _kolorWydzielenia(w.gatunek, w.wiek).withValues(alpha: 0.45),
                          borderColor: _kolorWydzielenia(w.gatunek, w.wiek),
                          borderStrokeWidth: 1,
                        ),
                  ],
                ),
              // warstwa potencjału krajowego (makro) — TYLKO przy oddaleniu;
              // po przybliżeniu znika, bo siatka 20 km traci sens (są hotspoty)
              if (_zoom < _zoomMikroMin)
                CircleLayer(
                  circles: [
                    for (final p in _potencjal)
                      CircleMarker(
                        point: p.pos,
                        radius: 7,
                        color: _kolor(p.score).withValues(alpha: 0.55),
                        borderColor: _kolor(p.score),
                        borderStrokeWidth: 1,
                      ),
                  ],
                ),
              // hotspoty szczegółowe — kółka w dedykowanej skali kolorów wg szansy
              // (rozciągniętej tak, by 36% i 87% wyraźnie się różniły)
              // KÓŁKA jako klikalne markery (CircleLayer nie obsługuje onTap!) —
              // każdy hotspot reaguje na dotyk i pokazuje dymek ze szczegółami.
              MarkerLayer(
                markers: [
                  for (final h in _hotspoty.where((x) => x.score < 80))
                    Marker(
                      point: h.pos,
                      width: 22,
                      height: 22,
                      child: GestureDetector(
                        onTap: () => _pokazSzczegol(h),
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _kolorHot(h.score).withValues(alpha: 0.85),
                            border: Border.all(color: const Color(0xFF3E2723), width: 1.2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              // grzybek 🍄 tylko dla najsilniejszych (>=80%), klikalny -> szczegóły
              MarkerLayer(
                markers: [
                  for (final h in _hotspoty.where((x) => x.score >= 80))
                    Marker(
                      point: h.pos,
                      width: 26,
                      height: 26,
                      child: GestureDetector(
                        onTap: () => _pokazSzczegol(h),
                        child: const Text('🍄', style: TextStyle(fontSize: 16)),
                      ),
                    ),
                ],
              ),
              // założone rewiry (pinezki)
              MarkerLayer(
                markers: [
                  for (final r in _rewiry)
                    Marker(
                      point: r.pos,
                      width: 36,
                      height: 36,
                      child: GestureDetector(
                        onTap: () => _menuRewiru(r),
                        child: const Icon(Icons.flag, color: Colors.redAccent, size: 28),
                      ),
                    ),
                ],
              ),
            ],
          ),

          if (!_trybRewiru)
            Positioned(
              top: 10, left: 12, right: 70,
              child: Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Colors.black54, size: 20),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: _szukajCtrl,
                          textInputAction: TextInputAction.search,
                          decoration: const InputDecoration(
                            hintText: 'Miejscowość lub współrzędne...',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onSubmitted: _szukaj,
                        ),
                      ),
                      if (_szukam)
                        const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                      else if (_szukajCtrl.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => setState(() => _szukajCtrl.clear()),
                        ),
                    ],
                  ),
                ),
              ),
            ),

          if (_trybRewiru)
            Positioned(
              top: 10, left: 12, right: 12,
              child: Card(
                color: const Color(0xFFD32F2F),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.touch_app, color: Colors.white),
                      SizedBox(width: 8),
                      Expanded(child: Text(
                        'Kliknij na mapie miejsce, gdzie chcesz założyć rewir',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      )),
                    ],
                  ),
                ),
              ),
            ),

          if (_laduje)
            const Positioned(
              top: 10, left: 0, right: 0,
              child: Center(child: Card(child: Padding(
                padding: EdgeInsets.all(8), child: Text('Ładuję dane...')))),
            ),

          if (_info != null)
            Positioned(
              top: 10, left: 12, right: 12,
              child: Card(
                color: Colors.amber.shade100,
                child: Padding(padding: const EdgeInsets.all(10), child: Text(_info!)),
              ),
            ),

          // legenda kolorów lasu (tylko gdy las włączony)
          if (_pokazLas)
            Positioned(
              left: 8, bottom: 90,
              child: Card(
                color: Colors.white.withValues(alpha: 0.92),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Gatunki drzew', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                      const Text('jasny = młody  ciemny = stary', style: TextStyle(fontSize: 9, color: Colors.black45)),
                      const SizedBox(height: 4),
                      for (final e in const [
                        // iglaste
                        ['SO', 'Sosna'], ['ŚW', 'Świerk'], ['MD', 'Modrzew'],
                        ['DG', 'Daglezja'], ['CIS', 'Cis'],
                        // liściaste
                        ['DB', 'Dąb'], ['DB.S', 'Dąb szypułkowy'],
                        ['DB.B', 'Dąb bezszypułkowy'], ['DB.C', 'Dąb czerwony'],
                        ['KL', 'Klon'], ['BK', 'Buk'], ['JS', 'Jesion'],
                        ['JW', 'Jawor'], ['WZ', 'Wiąz'], ['BRZ', 'Brzoza'],
                        ['LP', 'Lipa'], ['AK', 'Akacja'], ['TP', 'Topola'],
                        ['GB', 'Grab'], ['OS', 'Osika'],
                        ['OL', 'Olcha'], ['OL.S', 'Olcha szara'],
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            // młody (10 lat) — jasny
                            Container(width: 10, height: 12,
                                decoration: BoxDecoration(
                                    color: _kolorWydzielenia(e[0], 10),
                                    borderRadius: const BorderRadius.only(
                                      topLeft: Radius.circular(2),
                                      bottomLeft: Radius.circular(2)))),
                            // stary (100 lat) — ciemny
                            Container(width: 10, height: 12,
                                decoration: BoxDecoration(
                                    color: _kolorWydzielenia(e[0], 100),
                                    borderRadius: const BorderRadius.only(
                                      topRight: Radius.circular(2),
                                      bottomRight: Radius.circular(2)))),
                            const SizedBox(width: 5),
                            Text(e[1], style: const TextStyle(fontSize: 11)),
                          ]),
                        ),
                    ],
                  ),
                ),
              ),
            ),

          // panel dolny: suwak dnia
          // bottom = wysokosc paska systemu (Android 15+ edge-to-edge)
          Positioned(
            left: 0, right: 0,
            bottom: MediaQuery.viewPaddingOf(context).bottom,
            child: Card(
              margin: const EdgeInsets.all(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_dzien == 0 ? 'Dziś ($_dataISO)' : 'Za $_dzien dni  ($_dataISO)',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Row(
                      children: [
                        const Text('+0'),
                        Expanded(
                          child: Slider(
                            value: _dzien.toDouble(),
                            min: 0,
                            max: _prognoza ? 28 : 14,
                            divisions: _prognoza ? 28 : 14,
                            label: '+$_dzien',
                            onChanged: (v) => setState(() => _dzien = v.round()),
                            onChangeEnd: (_) => _odswiezWszystko(),
                          ),
                        ),
                        Text(_prognoza ? '+28' : '+14'),
                      ],
                    ),
                    // przełącznik trybu prognozy
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: _prognoza,
                          onChanged: (v) {
                            setState(() {
                              _prognoza = v;
                              // przy wyłączeniu prognozy cofnij suwak do max 14 dni
                              if (!_prognoza && _dzien > 14) _dzien = 14;
                            });
                            _odswiezWszystko();
                          },
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _prognoza
                                ? 'Prognoza pogody: ON (do 28 dni, mniej pewne)'
                                : 'Prognoza pogody: OFF (tylko dane historyczne)',
                            style: const TextStyle(fontSize: 12, color: Colors.black54),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // ZOOM +/- 
          FloatingActionButton.small(
            heroTag: 'zoomin',
            backgroundColor: Colors.white,
            foregroundColor: Colors.black87,
            onPressed: () => _map.move(_map.camera.center, _map.camera.zoom + 1),
            child: const Icon(Icons.add),
          ),
          const SizedBox(height: 6),
          FloatingActionButton.small(
            heroTag: 'zoomout',
            backgroundColor: Colors.white,
            foregroundColor: Colors.black87,
            onPressed: () => _map.move(_map.camera.center, _map.camera.zoom - 1),
            child: const Icon(Icons.remove),
          ),
          const SizedBox(height: 16),
          // TRYB DODAWANIA REWIRU
          FloatingActionButton.extended(
            heroTag: 'rewir',
            backgroundColor: _trybRewiru ? const Color(0xFFD32F2F) : Colors.grey.shade300,
            foregroundColor: _trybRewiru ? Colors.white : Colors.black87,
            onPressed: () => setState(() => _trybRewiru = !_trybRewiru),
            icon: Icon(_trybRewiru ? Icons.close : Icons.add_location_alt),
            label: Text(_trybRewiru ? 'Anuluj' : 'Dodaj rewir'),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'zarzadzaj',
            backgroundColor: Colors.white,
            foregroundColor: Colors.black87,
            onPressed: _panelRewirow,
            child: const Icon(Icons.list),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'las',
            backgroundColor: _pokazLas ? const Color(0xFF2E7D32) : Colors.grey.shade300,
            foregroundColor: _pokazLas ? Colors.white : Colors.black87,
            onPressed: _przelaczLas,
            icon: const Icon(Icons.forest),
            label: Text(_pokazLas ? 'Las: ON' : 'Las: OFF'),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'grzyby',
            onPressed: _laduje ? null : _wczytajHotspotyTutaj,
            icon: const Icon(Icons.search),
            label: const Text('Grzyby tutaj'),
          ),
        ],
      ),
    );
  }

  Widget _chipZakres(String etykieta, double od, double doG, void Function(void Function()) odswiez) {
    final aktywny = _prog.round() == od.round() && _progMax.round() == doG.round();
    return ChoiceChip(
      label: Text(etykieta, style: const TextStyle(fontSize: 12)),
      selected: aktywny,
      onSelected: (_) => odswiez(() {
        _prog = od;
        _progMax = doG;
      }),
    );
  }

  Widget _panelFiltrow() {
    return Drawer(
      child: SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setLocal) {
            void odswiezPanel(VoidCallback zmiana) {
              setLocal(zmiana);
              setState(zmiana);
            }
            return Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(children: [
                    Icon(Icons.tune), SizedBox(width: 8),
                    Text('Filtry', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // --- PRÓG / ZAKRES PRAWDOPODOBIEŃSTWA ---
                      const Text('Siła szansy', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      // szybkie zakresy
                      Wrap(
                        spacing: 6,
                        children: [
                          _chipZakres('Wszystkie', 30, 100, odswiezPanel),
                          _chipZakres('Słabe 30-50', 30, 50, odswiezPanel),
                          _chipZakres('Średnie 50-75', 50, 75, odswiezPanel),
                          _chipZakres('Mocne 75-100', 75, 100, odswiezPanel),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('Zakres: ${_prog.round()}–${_progMax.round()}%',
                          style: const TextStyle(fontSize: 13, color: Colors.black54)),
                      RangeSlider(
                        values: RangeValues(_prog, _progMax),
                        min: 30, max: 100, divisions: 14,
                        labels: RangeLabels('${_prog.round()}%', '${_progMax.round()}%'),
                        onChanged: (v) => odswiezPanel(() {
                          _prog = v.start;
                          _progMax = v.end;
                        }),
                      ),
                      const SizedBox(height: 8),

                      // --- GATUNKI GRZYBÓW ---
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text('Gatunki grzybów', style: TextStyle(fontWeight: FontWeight.bold)),
                        TextButton(
                          onPressed: () => odswiezPanel(() => _fGatunki.clear()),
                          child: const Text('Wszystkie'),
                        ),
                      ]),
                      Wrap(
                        spacing: 6, runSpacing: 2,
                        children: [
                          for (final g in kGatunki)
                            FilterChip(
                              label: Text(g, style: const TextStyle(fontSize: 12)),
                              selected: _fGatunki.contains(g),
                              onSelected: (sel) => odswiezPanel(() {
                                if (sel) {
                                  _fGatunki.add(g);
                                } else {
                                  _fGatunki.remove(g);
                                }
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // --- RODZAJ LASU ---
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text('Rodzaj lasu', style: TextStyle(fontWeight: FontWeight.bold)),
                        TextButton(
                          onPressed: () => odswiezPanel(() => _fLasy.clear()),
                          child: const Text('Wszystkie'),
                        ),
                      ]),
                      Wrap(
                        spacing: 6, runSpacing: 2,
                        children: [
                          for (final e in kLasy.entries)
                            FilterChip(
                              label: Text(e.value, style: const TextStyle(fontSize: 12)),
                              selected: _fLasy.contains(e.key),
                              onSelected: (sel) => odswiezPanel(() {
                                if (sel) {
                                  _fLasy.add(e.key);
                                } else {
                                  _fLasy.remove(e.key);
                                }
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // --- WIEK LASU ---
                      Text('Wiek lasu: ${_fWiek.start.round()}–${_fWiek.end.round()} lat',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      RangeSlider(
                        values: _fWiek, min: 0, max: 150, divisions: 30,
                        labels: RangeLabels('${_fWiek.start.round()}', '${_fWiek.end.round()}'),
                        onChanged: (v) => odswiezPanel(() => _fWiek = v),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => odswiezPanel(() {
                          _prog = 50; _fGatunki.clear(); _fLasy.clear();
                          _fWiek = const RangeValues(0, 150);
                        }),
                        child: const Text('Wyczyść'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          Navigator.of(ctx).pop(); // zamknij panel
                          _wczytajHotspotyTutaj(); // przeładuj z nowymi filtrami
                        },
                        child: const Text('Zastosuj'),
                      ),
                    ),
                  ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _przelaczLas() async {
    setState(() => _pokazLas = !_pokazLas);
    if (_pokazLas && _map.camera.zoom < _zoomLasMin) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Przybliż mapę (skala kilku km), aby zobaczyć las.')));
      }
      return;
    }
    setState(() => _laduje = true);
    try {
      await _wczytajLas();
    } catch (e) {
      _info = 'Błąd lasu: $e';
    } finally {
      if (mounted) setState(() => _laduje = false);
    }
  }

  Future<void> _wczytajHotspotyTutaj() async {
    setState(() => _laduje = true);
    try {
      await _wczytajHotspoty();
      if (_hotspoty.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Brak hotspotów w tym widoku na wybrany dzień.')));
      }
    } catch (e) {
      _info = 'Błąd: $e';
    } finally {
      if (mounted) setState(() => _laduje = false);
    }
  }

  void _pokazLasInfo(_Wydzielenie w, [LatLng? cel]) {
    const nazwy = {
      'SO': 'Sosna', 'SOC': 'Sosna czarna', 'SW': 'Świerk', 'ŚW': 'Świerk',
      'JD': 'Jodła', 'BK': 'Buk', 'DB': 'Dąb', 'DBS': 'Dąb szypułkowy',
      'DBB': 'Dąb bezszypułkowy', 'BRZ': 'Brzoza', 'OL': 'Olcha', 'OS': 'Osika',
      'MD': 'Modrzew', 'GB': 'Grab',
    };
    final nazwa = nazwy[w.gatunek.toUpperCase()] ?? w.gatunek;
    final faza = w.wiek < 20 ? 'młodnik'
        : w.wiek < 40 ? 'drągowina'
        : w.wiek < 80 ? 'drzewostan dojrzały'
        : 'starodrzew';
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(width: 16, height: 16,
                  decoration: BoxDecoration(color: _kolorWydzielenia(w.gatunek, w.wiek),
                      borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 8),
              Text(nazwa, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            ]),
            const SizedBox(height: 8),
            Text('Wiek: ${w.wiek} lat  ($faza)'),
            Text('Kod gatunku: ${w.gatunek}', style: const TextStyle(color: Colors.black54, fontSize: 13)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _nawigujDo(cel ?? w.srodek);
                },
                icon: const Icon(Icons.navigation, size: 18),
                label: const Text('Nawiguj do tego miejsca'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // klik w pinezkę rewiru -> opcje (na razie: usuń)
  void _menuRewiru(_Rewir r) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.flag, color: Colors.redAccent),
              title: Text(r.nazwa, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${r.pos.latitude.toStringAsFixed(4)}, ${r.pos.longitude.toStringAsFixed(4)}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Usuń ten rewir'),
              onTap: () async {
                Navigator.of(context).pop();
                await _usunRewiry([r.id]);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _usunRewiry(List<int> ids) async {
    try {
      for (final id in ids) {
        await supabase.rpc('usun_rewir', params: {'in_id': id});
      }
      await _wczytajRewiry();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Usunięto ${ids.length} rewir(ów)')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Błąd usuwania: $e')));
      }
    }
  }

  // panel listy rewirów z zaznaczaniem i usuwaniem hurtem
  void _panelRewirow() {
    final zaznaczone = <int>{};
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setLocal) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (_, scroll) => Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Twoje rewiry', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              const Divider(height: 1),
              Expanded(
                child: _rewiry.isEmpty
                    ? const Center(child: Padding(padding: EdgeInsets.all(24),
                        child: Text('Nie masz jeszcze żadnych rewirów.')))
                    : ListView(
                        controller: scroll,
                        children: [
                          for (final r in _rewiry)
                            CheckboxListTile(
                              value: zaznaczone.contains(r.id),
                              onChanged: (v) => setLocal(() {
                                if (v == true) {
                                  zaznaczone.add(r.id);
                                } else {
                                  zaznaczone.remove(r.id);
                                }
                              }),
                              title: Text(r.nazwa),
                              subtitle: Text('${r.pos.latitude.toStringAsFixed(3)}, ${r.pos.longitude.toStringAsFixed(3)}'),
                              secondary: IconButton(
                                icon: const Icon(Icons.my_location, size: 20),
                                tooltip: 'Pokaż na mapie',
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  _map.move(r.pos, 12);
                                },
                              ),
                            ),
                        ],
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: const Icon(Icons.close),
                        label: const Text('Zamknij'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: Colors.red),
                        onPressed: zaznaczone.isEmpty ? null : () async {
                          Navigator.of(ctx).pop();
                          await _usunRewiry(zaznaczone.toList());
                        },
                        icon: const Icon(Icons.delete),
                        label: Text('Usuń (${zaznaczone.length})'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // wyszukiwanie: rozpoznaje współrzędne (dwie liczby) albo nazwę (przez Nominatim/OSM)
  Future<void> _szukaj(String tekst) async {
    final q = tekst.trim();
    if (q.isEmpty) return;

    // 1) próba: czy to współrzędne? np. "52.06, 21.45" albo "52.06 21.45"
    final coord = RegExp(r'^\s*(-?\d{1,2}[.,]\d+)\s*[, ]\s*(-?\d{1,3}[.,]\d+)\s*$');
    final m = coord.firstMatch(q);
    if (m != null) {
      final lat = double.tryParse(m.group(1)!.replaceAll(',', '.'));
      final lon = double.tryParse(m.group(2)!.replaceAll(',', '.'));
      if (lat != null && lon != null && lat > 48 && lat < 56 && lon > 13 && lon < 25) {
        _map.move(LatLng(lat, lon), 13);
        return;
      }
    }

    // 2) nazwa miejscowości -> Nominatim (OSM). Ograniczamy do Polski.
    setState(() => _szukam = true);
    try {
      final uri = Uri.parse(
          'https://nominatim.openstreetmap.org/search'
          '?q=${Uri.encodeComponent(q)}&format=json&limit=1&countrycodes=pl');
      final res = await http.get(uri, headers: {'User-Agent': 'PredictMushroomsPRO/1.0'});
      if (res.statusCode == 200) {
        final lista = jsonDecode(res.body) as List;
        if (lista.isNotEmpty) {
          final r = lista.first as Map<String, dynamic>;
          final lat = double.parse(r['lat'].toString());
          final lon = double.parse(r['lon'].toString());
          _map.move(LatLng(lat, lon), 13);
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Nie znaleziono miejsca')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Błąd wyszukiwania: $e')));
      }
    } finally {
      if (mounted) setState(() => _szukam = false);
    }
  }

  // otwiera zewnętrzną nawigację (Google Maps / domyślna mapa) z trasą do punktu
  Future<void> _nawigujDo(LatLng cel) async {
    final lat = cel.latitude;
    final lon = cel.longitude;
    // 1) próba natywnej nawigacji Google (Android) — od razu trasa
    final geoNav = Uri.parse('google.navigation:q=$lat,$lon');
    // 2) fallback: uniwersalny link Google Maps (działa wszędzie, też w przeglądarce)
    final webMaps = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=$lat,$lon');
    try {
      if (await canLaunchUrl(geoNav)) {
        await launchUrl(geoNav, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(webMaps, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // ostatnia deska ratunku — pokaż współrzędne do ręcznego wpisania
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Współrzędne: ${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}')));
      }
    }
  }

  void _pokazSzczegol(_Pkt h) async {
    // dociągnij WSZYSTKIE gatunki w tym wydzieleniu (kratka pokazuje tylko najsilniejszy)
    List<Map<String, dynamic>> gatunki = [];
    try {
      final res = await supabase.rpc('hotspots_w_punkcie', params: {
        'in_lat': h.pos.latitude,
        'in_lon': h.pos.longitude,
        'in_date': _dataISO,
        'in_tryb': _prognoza ? 'forecast' : 'historia',
        // promień wyszukiwania dopasowany do siatki agregacji kółek przy danym zoomie
        // (kółko to środek kratki, więc dymek musi szukać w jej obrębie)
        'in_promien': (_siatkaDlaZoomu(_map.camera.zoom) * 0.75).clamp(0.002, 0.05),
      });
      gatunki = ((res as List?) ?? []).cast<Map<String, dynamic>>();
    } catch (_) {}
    if (!mounted) return;

    // SCAL DUPLIKATY: ten sam gatunek z kilku wydzieleń w punkcie -> jeden wpis,
    // najwyższy procent. Sortuj malejąco wg szansy.
    final Map<String, int> najlepsze = {};
    for (final g in gatunki) {
      final sp = (g['species'] ?? '').toString();
      final pr = _toI(g['prob']);
      if (!najlepsze.containsKey(sp) || pr > najlepsze[sp]!) najlepsze[sp] = pr;
    }
    final lista = najlepsze.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    String drzewo = '', tStr = '—';
    int wiek = 0;
    double? wilg;
    double? deszcz7;
    if (gatunki.isNotEmpty) {
      final g0 = gatunki.first;
      drzewo = (g0['drzewo'] ?? '').toString();
      wiek = _toI(g0['wiek']);
      final t = g0['t_dev'];
      tStr = t == null ? '—' : '${_toD(t).toStringAsFixed(1)}°C';
      if (g0['wilg'] != null) wilg = _toD(g0['wilg']);
      if (g0['deszcz7'] != null) deszcz7 = _toD(g0['deszcz7']);
    }

    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('🍄 ${h.pos.latitude.toStringAsFixed(4)}, ${h.pos.longitude.toStringAsFixed(4)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                FilledButton.icon(
                  onPressed: () => _nawigujDo(h.pos),
                  icon: const Icon(Icons.navigation, size: 18),
                  label: const Text('Nawiguj'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
            ),
            Text('Dzień: $_dataISO', style: const TextStyle(color: Colors.black54, fontSize: 13)),
            if (drzewo.isNotEmpty)
              Text('Las: $drzewo $wiek lat  •  temp.: $tStr',
                  style: const TextStyle(color: Colors.black54, fontSize: 13)),
            const Divider(),
            if (lista.isEmpty)
              Text('${h.opis}: ${h.score}%')
            else
              // przewijalna lista, ograniczona wysokością — nie przepełni ekranu
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final e in lista)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text(e.key)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: _kolorHot(e.value).withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text('${e.value}%',
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            if (wilg != null || deszcz7 != null) ...[
              const Divider(height: 8),
              Row(
                children: [
                  const Icon(Icons.water_drop, size: 16, color: Colors.blue),
                  const SizedBox(width: 6),
                  Text('Wilgotność ściółki: ',
                      style: const TextStyle(fontSize: 13, color: Colors.black87)),
                  Text(wilg != null ? '${wilg.round()}%' : '—',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ],
              ),
              if (wilg != null) ...[
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: wilg / 100.0,
                    minHeight: 7,
                    backgroundColor: Colors.grey.shade300,
                    valueColor: AlwaysStoppedAnimation(
                      wilg < 35 ? Colors.orange : (wilg < 60 ? Colors.lightGreen : Colors.green),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.umbrella, size: 16, color: Colors.indigo),
                  const SizedBox(width: 6),
                  Text('Deszcz (ostatnie 7 dni): ',
                      style: const TextStyle(fontSize: 13, color: Colors.black87)),
                  Text(deszcz7 != null ? '${deszcz7.toStringAsFixed(1)} mm' : '—',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ],
              ),
            ] else
              const Text('Opad i wilgotność ściółki — wkrótce',
                  style: TextStyle(color: Colors.black38, fontSize: 11, fontStyle: FontStyle.italic)),
          ],
        ),
      ),
    );
  }

  void _pokazSzczegolStary(_Pkt h) {}
}

class _Pkt {
  final LatLng pos;
  final int score;
  final String opis;
  _Pkt(this.pos, this.score, this.opis);
}

class _Rewir {
  final int id;
  final String nazwa;
  final LatLng pos;
  _Rewir(this.id, this.nazwa, this.pos);
}

class _Wydzielenie {
  final List<List<LatLng>> pierscienie; // jeden lub więcej wielokątów
  final String gatunek;
  final int wiek;
  _Wydzielenie(this.pierscienie, this.gatunek, this.wiek);

  // środek (do dymka po kliknięciu) — średnia punktów pierwszego pierścienia
  LatLng get srodek {
    final p = pierscienie.first;
    double sx = 0, sy = 0;
    for (final c in p) {
      sx += c.longitude;
      sy += c.latitude;
    }
    return LatLng(sy / p.length, sx / p.length);
  }
}