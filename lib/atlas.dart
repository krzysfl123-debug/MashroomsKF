import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Dane gatunku z naszego modelu (parametry zgodne ze słownikiem GATUNKI w agencie).
class GatunekInfo {
  final String nazwa;
  final List<String> symbioza; // kody drzew
  final int wiekMin, wiekMax;
  final double tOpt; // optymalna temperatura
  final int wilgProg; // próg wilgotności ściółki
  final int dniGrzybni; // dni ładowania grzybni
  final double ochlProg; // wymagane ochłodzenie (0 = nie wymaga)
  final int lag; // dni od startu do zbioru
  final List<int> miesiace;
  const GatunekInfo(this.nazwa, this.symbioza, this.wiekMin, this.wiekMax,
      this.tOpt, this.wilgProg, this.dniGrzybni, this.ochlProg, this.lag, this.miesiace);
}

/// Mapowanie naszych nazw na TYTUŁY artykułów w polskiej Wikipedii.
/// Niektóre grzyby Wiki trzyma pod oficjalną nazwą mykologiczną, nie potoczną.
/// Gdy nazwa nie jest tu wymieniona — używamy jej wprost (zwykle się zgadza).
const Map<String, String> kWikiNazwy = {
  'Kurka': 'Pieprznik jadalny',
  'Rydz': 'Mleczaj rydz',
  'Borowik ceglastoporowy': 'Krasnoborowik ceglastopory',
};

/// Zwraca tytuł artykułu Wiki dla danej nazwy gatunku.
String wikiTytul(String nazwa) => kWikiNazwy[nazwa] ?? nazwa;

/// Pełne nazwy kodów drzew (do czytelnego wyświetlania).
const Map<String, String> kNazwyDrzew = {
  'SO': 'sosna', 'ŚW': 'świerk', 'JD': 'jodła', 'BK': 'buk', 'DB': 'dąb',
  'BRZ': 'brzoza', 'OL': 'olcha', 'OS': 'osika', 'MD': 'modrzew', 'GB': 'grab',
  'ALL': 'różne drzewa',
};

const List<String> _msc = ['', 'sty', 'lut', 'mar', 'kwi', 'maj', 'cze',
  'lip', 'sie', 'wrz', 'paź', 'lis', 'gru'];

/// Dane wszystkich 14 gatunków — odwzorowanie słownika GATUNKI z nocny_agent.py.
const List<GatunekInfo> kAtlasGatunki = [
  GatunekInfo('Borowik szlachetny', ['SO','ŚW','DB','BK'], 40, 999, 16.0, 55, 10, 2.5, 6, [6,7,8,9,10,11]),
  GatunekInfo('Borowik usiatkowany', ['DB','BK','GB'], 40, 999, 19.0, 45, 5, 0.0, 4, [5,6,7,8,9]),
  GatunekInfo('Borowik ceglastoporowy', ['ŚW','JD','BK','DB'], 30, 999, 17.0, 50, 7, 1.0, 5, [6,7,8,9,10,11]),
  GatunekInfo('Podgrzybek brunatny', ['SO','ŚW'], 30, 999, 15.0, 50, 7, 1.5, 5, [8,9,10,11]),
  GatunekInfo('Podgrzybek zajączek', ['SO','DB','BK','BRZ'], 20, 999, 16.0, 45, 5, 0.0, 4, [6,7,8,9,10]),
  GatunekInfo('Maślak zwyczajny', ['SO'], 5, 40, 15.0, 35, 3, 0.0, 2, [6,7,8,9,10,11]),
  GatunekInfo('Maślak sitarz', ['SO'], 10, 60, 14.0, 35, 3, 0.0, 2, [7,8,9,10,11]),
  GatunekInfo('Koźlarz babka', ['BRZ'], 10, 999, 18.0, 40, 3, 0.0, 2, [6,7,8,9,10]),
  GatunekInfo('Koźlarz czerwony', ['OS'], 10, 999, 18.0, 40, 3, 0.0, 2, [6,7,8,9,10]),
  GatunekInfo('Kurka', ['SO','ŚW','DB','BK','BRZ'], 20, 999, 17.0, 50, 6, 0.0, 3, [6,7,8,9,10]),
  GatunekInfo('Rydz', ['SO','ŚW'], 10, 45, 12.0, 50, 7, 2.0, 4, [8,9,10,11]),
  GatunekInfo('Czubajka kania', ['ALL'], 0, 999, 18.0, 40, 5, 0.0, 4, [7,8,9,10]),
  GatunekInfo('Gołąbek zielonawy', ['DB','BK','BRZ'], 30, 999, 19.0, 45, 5, 0.0, 3, [6,7,8,9]),
  GatunekInfo('Gąska zielonka', ['SO'], 30, 999, 8.0, 50, 8, 3.0, 5, [9,10,11,12]),
];

/// Mała miniaturka gatunku na liście — pobiera główne zdjęcie z Wiki (summary).
/// Leniwie: ładuje się dopiero gdy kafelek powstaje (przy przewijaniu).
class _Miniatura extends StatefulWidget {
  final String nazwa;
  const _Miniatura(this.nazwa);
  @override
  State<_Miniatura> createState() => _MiniaturaState();
}

class _MiniaturaState extends State<_Miniatura> {
  String? _url;
  bool _gotowe = false;

  @override
  void initState() {
    super.initState();
    _pobierz();
  }

  Future<void> _pobierz() async {
    try {
      final uri = Uri.parse(
          'https://pl.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(wikiTytul(widget.nazwa))}');
      final res = await http.get(uri, headers: {'User-Agent': 'PredictMushroomsPRO/1.0'});
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final t = j['thumbnail']?['source'] ?? j['originalimage']?['source'];
        if (t != null) _url = t.toString();
      }
    } catch (_) {}
    if (mounted) setState(() => _gotowe = true);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 56, height: 56,
        child: !_gotowe
            ? Container(color: Colors.grey.shade200,
                child: const Center(child: SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))))
            : (_url != null
                ? Image.network(_url!, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(color: Colors.green.shade100,
                        child: const Icon(Icons.eco, color: Colors.green)))
                : Container(color: Colors.green.shade100,
                    child: const Icon(Icons.eco, color: Colors.green))),
      ),
    );
  }
}

/// Ekran główny atlasu — przewijalna lista gatunków z danymi modelu.
class AtlasScreen extends StatelessWidget {
  const AtlasScreen({super.key});

  String _drzewa(GatunekInfo g) =>
      g.symbioza.map((k) => kNazwyDrzew[k] ?? k).join(', ');

  String _wiek(GatunekInfo g) {
    if (g.wiekMin == 0 && g.wiekMax >= 999) return 'dowolny wiek';
    if (g.wiekMax >= 999) return '${g.wiekMin}+ lat';
    return '${g.wiekMin}–${g.wiekMax} lat';
  }

  String _miesiace(GatunekInfo g) =>
      '${_msc[g.miesiace.first]}–${_msc[g.miesiace.last]}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🍄 Atlas grzybów')),
      body: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: kAtlasGatunki.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (context, i) {
          final g = kAtlasGatunki[i];
          return Card(
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => GatunekSzczegolScreen(gatunek: g))),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Miniatura(g.nazwa),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(g.nazwa,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              ),
                              const Icon(Icons.chevron_right, color: Colors.black38),
                            ],
                          ),
                          const SizedBox(height: 6),
                          _wiersz(Icons.park, 'Drzewa: ${_drzewa(g)}'),
                          _wiersz(Icons.straighten, 'Wiek lasu: ${_wiek(g)}'),
                          _wiersz(Icons.calendar_month, 'Sezon: ${_miesiace(g)}'),
                          _wiersz(Icons.water_drop,
                              'Wilgotność ściółki: min ${g.wilgProg}%  •  ładowanie ~${g.dniGrzybni} dni'),
                          _wiersz(Icons.schedule,
                              'Wzrost po starcie: ~${g.lag} dni'
                              '${g.ochlProg > 0 ? '  •  wymaga ochłodzenia' : ''}'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _wiersz(IconData ikona, String tekst) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(ikona, size: 16, color: Colors.green.shade700),
            const SizedBox(width: 8),
            Expanded(child: Text(tekst, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}

/// Ekran szczegółów — dane modelu + treść z Wikipedii (zaciągana na żądanie).
class GatunekSzczegolScreen extends StatefulWidget {
  final GatunekInfo gatunek;
  const GatunekSzczegolScreen({super.key, required this.gatunek});

  @override
  State<GatunekSzczegolScreen> createState() => _GatunekSzczegolScreenState();
}

class _GatunekSzczegolScreenState extends State<GatunekSzczegolScreen> {
  bool _laduje = true;
  String? _opis;
  final List<String> _zdjecia = [];
  String? _link;
  String? _blad;

  @override
  void initState() {
    super.initState();
    _wczytajWiki();
  }

  Future<void> _wczytajWiki() async {
    final nazwa = wikiTytul(widget.gatunek.nazwa);
    try {
      // 1) główne zdjęcie + link z REST summary (szybkie, ma originalimage)
      final sumUri = Uri.parse(
          'https://pl.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(nazwa)}');
      final sumRes = await http.get(sumUri,
          headers: {'User-Agent': 'PredictMushroomsPRO/1.0'});
      if (sumRes.statusCode == 200) {
        final j = jsonDecode(sumRes.body) as Map<String, dynamic>;
        _link = j['content_urls']?['desktop']?['page']?.toString();
        final thumb = j['originalimage']?['source'] ?? j['thumbnail']?['source'];
        if (thumb != null) _zdjecia.add(thumb.toString());
      }

      // 2) PEŁNA treść artykułu jako czysty tekst (z sekcjami: opis, występowanie,
      //    wartość kulinarna itd.) — endpoint extracts, explaintext=czysty tekst.
      final txtUri = Uri.parse(
          'https://pl.wikipedia.org/w/api.php?action=query&format=json&origin=*'
          '&prop=extracts&explaintext=1&exsectionformat=plain'
          '&titles=${Uri.encodeComponent(nazwa)}');
      final txtRes = await http.get(txtUri,
          headers: {'User-Agent': 'PredictMushroomsPRO/1.0'});
      if (txtRes.statusCode == 200) {
        final j = jsonDecode(txtRes.body) as Map<String, dynamic>;
        final pages = (j['query']?['pages'] ?? {}) as Map<String, dynamic>;
        for (final p in pages.values) {
          final ex = p['extract']?.toString();
          if (ex != null && ex.trim().isNotEmpty) {
            // skróć bardzo długie artykuły do rozsądnej długości (pierwsze ~2500 znaków)
            _opis = ex.length > 2500 ? '${ex.substring(0, 2500)}…' : ex;
          }
        }
      }

      // 3) więcej zdjęć z galerii strony (do 6 łącznie)
      final imgUri = Uri.parse(
          'https://pl.wikipedia.org/w/api.php?action=query&format=json&origin=*'
          '&prop=images&titles=${Uri.encodeComponent(nazwa)}&imlimit=20');
      final imgRes = await http.get(imgUri,
          headers: {'User-Agent': 'PredictMushroomsPRO/1.0'});
      if (imgRes.statusCode == 200) {
        final j = jsonDecode(imgRes.body) as Map<String, dynamic>;
        final pages = (j['query']?['pages'] ?? {}) as Map<String, dynamic>;
        final tytulyPlikow = <String>[];
        for (final p in pages.values) {
          final imgs = (p['images'] ?? []) as List;
          for (final im in imgs) {
            final t = im['title']?.toString() ?? '';
            if (RegExp(r'\.(jpg|jpeg|png)$', caseSensitive: false).hasMatch(t)) {
              tytulyPlikow.add(t);
            }
          }
        }
        for (final tytul in tytulyPlikow.take(8)) {
          if (_zdjecia.length >= 6) break;
          final url = await _urlObrazu(tytul);
          if (url != null && !_zdjecia.contains(url)) _zdjecia.add(url);
        }
      }
    } catch (e) {
      _blad = e.toString();
    } finally {
      if (mounted) setState(() => _laduje = false);
    }
  }

  /// Zamienia tytuł pliku ("File:Xxx.jpg") na bezpośredni URL obrazu (przeskalowany).
  Future<String?> _urlObrazu(String tytulPliku) async {
    try {
      final uri = Uri.parse(
          'https://pl.wikipedia.org/w/api.php?action=query&format=json&origin=*'
          '&prop=imageinfo&iiprop=url&iiurlwidth=600'
          '&titles=${Uri.encodeComponent(tytulPliku)}');
      final res = await http.get(uri, headers: {'User-Agent': 'PredictMushroomsPRO/1.0'});
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final pages = (j['query']?['pages'] ?? {}) as Map<String, dynamic>;
        for (final p in pages.values) {
          final ii = (p['imageinfo'] ?? []) as List;
          if (ii.isNotEmpty) {
            return (ii.first['thumburl'] ?? ii.first['url'])?.toString();
          }
        }
      }
    } catch (_) {}
    return null;
  }

  String _drzewa(GatunekInfo g) =>
      g.symbioza.map((k) => kNazwyDrzew[k] ?? k).join(', ');

  @override
  Widget build(BuildContext context) {
    final g = widget.gatunek;
    return Scaffold(
      appBar: AppBar(title: Text(g.nazwa)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // --- nasze dane z modelu ---
          Card(
            color: Colors.green.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Dane z modelu', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Text('Drzewa symbiotyczne: ${_drzewa(g)}'),
                  Text('Optymalna temperatura: ${g.tOpt.toStringAsFixed(0)}°C'),
                  Text('Próg wilgotności ściółki: ${g.wilgProg}%'),
                  Text('Ładowanie grzybni: ~${g.dniGrzybni} dni wilgoci'),
                  Text(g.ochlProg > 0
                      ? 'Wymaga ochłodzenia (sygnał startu): ~${g.ochlProg.toStringAsFixed(1)}°C'
                      : 'Nie wymaga ochłodzenia (rośnie latem)'),
                  Text('Czas wzrostu po starcie: ~${g.lag} dni do zbioru'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // --- treść z Wikipedii ---
          if (_laduje)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Column(children: [
                CircularProgressIndicator(),
                SizedBox(height: 8),
                Text('Pobieram opis z Wikipedii...'),
              ])),
            )
          else ...[
            if (_zdjecia.isNotEmpty)
              SizedBox(
                height: 180,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _zdjecia.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(_zdjecia[i], width: 240, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                            width: 240, color: Colors.grey.shade200,
                            child: const Icon(Icons.broken_image, color: Colors.grey))),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (_opis != null)
              Text(_opis!, style: const TextStyle(fontSize: 14, height: 1.4))
            else
              Text(_blad != null
                  ? 'Nie udało się pobrać opisu z Wikipedii.'
                  : 'Brak opisu w Wikipedii dla tego gatunku.'),
            const SizedBox(height: 12),
            if (_link != null)
              Text('Źródło: Wikipedia (CC BY-SA)',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ],
      ),
    );
  }
}