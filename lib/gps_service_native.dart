import 'package:geolocator/geolocator.dart';

/// Pobiera aktualną pozycję GPS (Android/iOS).
/// Zwraca (lat, lon) lub null gdy brak uprawnień / błąd.
Future<({double lat, double lon})?> getCurrentGpsLocation() async {
  LocationPermission perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) {
    perm = await Geolocator.requestPermission();
  }
  if (perm == LocationPermission.denied ||
      perm == LocationPermission.deniedForever) {
    return null;
  }
  final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high);
  return (lat: pos.latitude, lon: pos.longitude);
}