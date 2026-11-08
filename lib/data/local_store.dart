import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Small persistence facade. Identity seeds and room PINs go to the platform
/// keystore when available; a preferences-backed fallback keeps the app usable
/// on desktop systems without a keyring.
class LocalStore {
  LocalStore._(this._prefs, this._secure, this._secureAvailable);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  final bool _secureAvailable;

  static Future<LocalStore> open({bool useSecureStorage = true}) async {
    final prefs = await SharedPreferences.getInstance();
    var secureAvailable = useSecureStorage;
    const secure = FlutterSecureStorage();
    if (secureAvailable) {
      try {
        await secure.read(key: 'blue_room.probe');
      } catch (error) {
        secureAvailable = false;
        debugPrint(
          'Secure storage unavailable, falling back to preferences: $error',
        );
      }
    }
    return LocalStore._(prefs, secure, secureAvailable);
  }

  Future<String?> readSecret(String key) async {
    if (_secureAvailable) {
      try {
        final value = await _secure.read(key: key);
        if (value != null) return value;
      } catch (_) {
        // Fall through to preferences.
      }
    }
    return _prefs.getString('secret.$key');
  }

  Future<void> writeSecret(String key, String value) async {
    if (_secureAvailable) {
      try {
        await _secure.write(key: key, value: value);
        return;
      } catch (_) {
        // Fall through to preferences.
      }
    }
    await _prefs.setString('secret.$key', value);
  }

  Future<void> deleteSecret(String key) async {
    if (_secureAvailable) {
      try {
        await _secure.delete(key: key);
      } catch (_) {
        // Ignore.
      }
    }
    await _prefs.remove('secret.$key');
  }

  String? readPref(String key) => _prefs.getString(key);

  Future<void> writePref(String key, String value) =>
      _prefs.setString(key, value);
}
