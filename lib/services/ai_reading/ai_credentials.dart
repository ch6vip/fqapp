import '../native_secure_key_storage.dart';
import '../secure_key_provider.dart';

/// API keys live only in platform secure storage. The settings box stores a
/// random `credentialRef`; backups and logs never contain this value.
class AiCredentialStore {
  AiCredentialStore({SecureKeyStorage? storage})
    : _storage = storage ?? defaultSecureKeyStorage();

  static final instance = AiCredentialStore();
  static const _prefix = 'fqapp_ai_credential_';

  final SecureKeyStorage _storage;

  String _key(String ref) => '$_prefix$ref';

  Future<String?> read(String? ref) async {
    if (ref == null || ref.isEmpty) return null;
    try {
      final value = await _storage.read(_key(ref));
      return value == null || value.trim().isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String ref, String key) =>
      _storage.write(_key(ref), key.trim());

  Future<void> delete(String ref) => _storage.delete(_key(ref));

  Future<bool> has(String? ref) async => await read(ref) != null;
}
