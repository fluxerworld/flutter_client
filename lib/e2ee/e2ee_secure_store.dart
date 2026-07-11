// Durable, OS-backed storage for the two pieces of E2EE state that must OUTLIVE
// the cache-dir key-store database: the account pickle key and a "we already
// registered a device for this user" breadcrumb (the device id).
//
// Why this exists — and why it is a deliberate improvement over the web/RN
// reference clients: both of those gate their bootstrap solely on the presence
// of the local account row. If that database is lost (app-data wipe, a transient
// open error, a reinstall that keeps the keychain), they silently mint a BRAND
// NEW Olm identity and register it — the documented per-launch device churn
// (one user reached 31 devices). Keeping the device id in the OS keychain lets
// the manager tell "genuine first run" (no breadcrumb) apart from "cache lost
// but we DID register before" (breadcrumb present) and avoid the silent re-mint.
//
// The pickle key lives here too (not in the cache db) so the pickles in the
// cache db are useless on their own — mirroring the auth-token storage idiom.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-user durable E2EE identity state. Keyed by user id so signing in as a
/// different user on the same install can never reuse the previous identity.
abstract interface class E2eeSecureStore {
  /// The 32-byte key that encrypts every pickle in the cache-dir key store.
  Future<Uint8List?> readPickleKey(String userId);
  Future<void> writePickleKey(String userId, Uint8List key);

  /// The breadcrumb: the device id we last registered for this user. Its mere
  /// presence means "this install has registered before" even if the cache db
  /// is gone.
  Future<String?> readDeviceId(String userId);
  Future<void> writeDeviceId(String userId, String deviceId);

  /// Clear both — called on logout/account switch so a later user cannot be
  /// linked to this identity.
  Future<void> clear(String userId);
}

class FlutterSecureE2eeStore implements E2eeSecureStore {
  FlutterSecureE2eeStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              mOptions: MacOsOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  final FlutterSecureStorage _storage;

  static const String _pickleKeyPrefix = 'e2ee_pickle_key_';
  static const String _deviceIdPrefix = 'e2ee_device_id_';

  @override
  Future<Uint8List?> readPickleKey(String userId) async {
    final encoded = await _storage.read(key: '$_pickleKeyPrefix$userId');
    if (encoded == null) {
      return null;
    }
    return base64Decode(encoded);
  }

  @override
  Future<void> writePickleKey(String userId, Uint8List key) =>
      _storage.write(key: '$_pickleKeyPrefix$userId', value: base64Encode(key));

  @override
  Future<String?> readDeviceId(String userId) =>
      _storage.read(key: '$_deviceIdPrefix$userId');

  @override
  Future<void> writeDeviceId(String userId, String deviceId) =>
      _storage.write(key: '$_deviceIdPrefix$userId', value: deviceId);

  @override
  Future<void> clear(String userId) async {
    await _storage.delete(key: '$_pickleKeyPrefix$userId');
    await _storage.delete(key: '$_deviceIdPrefix$userId');
  }
}

/// In-memory implementation for unit tests.
class MapE2eeSecureStore implements E2eeSecureStore {
  final Map<String, Uint8List> _pickleKeys = <String, Uint8List>{};
  final Map<String, String> _deviceIds = <String, String>{};

  @override
  Future<Uint8List?> readPickleKey(String userId) async => _pickleKeys[userId];

  @override
  Future<void> writePickleKey(String userId, Uint8List key) async {
    _pickleKeys[userId] = key;
  }

  @override
  Future<String?> readDeviceId(String userId) async => _deviceIds[userId];

  @override
  Future<void> writeDeviceId(String userId, String deviceId) async {
    _deviceIds[userId] = deviceId;
  }

  @override
  Future<void> clear(String userId) async {
    _pickleKeys.remove(userId);
    _deviceIds.remove(userId);
  }
}
