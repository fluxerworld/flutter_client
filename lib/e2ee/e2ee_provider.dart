// Riverpod wiring for the E2EE stack. Kept in lib/e2ee (first-party) so the
// pristine upstream dart_sdk submodule is untouched.
import 'package:fluxer_app/core/api/fluxer_client_provider.dart';
import 'package:fluxer_app/e2ee/e2ee_api.dart';
import 'package:fluxer_app/e2ee/e2ee_key_store.dart';
import 'package:fluxer_app/e2ee/e2ee_manager.dart';
import 'package:fluxer_app/e2ee/e2ee_secure_store.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'e2ee_provider.g.dart';

/// The E2EE key-store Drift database, as its OWN keepAlive singleton so exactly
/// one connection to the `fluxer_e2ee` db is ever opened even if the manager is
/// rebuilt (e.g. when the base URL / Dio changes).
@Riverpod(keepAlive: true)
E2eeKeyStore e2eeKeyStore(Ref ref) => E2eeKeyStore();

/// The E2EE orchestrator singleton. Depends on the authenticated Dio for its
/// REST client; reads (not watches) the key store so a Dio rebuild doesn't
/// reopen the database.
@Riverpod(keepAlive: true)
E2eeManager e2eeManager(Ref ref) {
  final dio = ref.watch(fluxerDioProvider);
  return E2eeManager(
    api: E2eeApi(dio),
    store: ref.read(e2eeKeyStoreProvider),
    secure: FlutterSecureE2eeStore(),
  );
}
