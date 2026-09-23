import 'package:connectivity_plus/connectivity_plus.dart';

/// The app's one rule for when it may use the network: Wi-Fi or wired only.
///
/// Every download it makes is large (a 1.3 GB model, a 175 MB encoder) or
/// optional (guide updates), and the person holding the phone may be on a
/// prepaid data pack in the middle of an emergency. Spending that on a
/// background fetch is a cost they never agreed to, so mobile data is treated
/// the same as no connection. A phone tethered to another phone's hotspot
/// reports Wi-Fi, which is the right answer: that is a deliberate choice.
class NetworkPolicy {
  const NetworkPolicy._();

  /// Whether [results] include a connection the app is allowed to use.
  static bool allows(List<ConnectivityResult> results) => results.any(
    (r) => r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet,
  );

  /// Whether the device is on Wi-Fi or ethernet right now.
  static Future<bool> onWifi() async =>
      allows(await Connectivity().checkConnectivity());
}
