// Warunkowy import: na mobile/desktop -> native (geolocator),
// na web -> stub (GPS niedostępny w przeglądarce).
export 'gps_service_stub.dart'
    if (dart.library.io) 'gps_service_native.dart';