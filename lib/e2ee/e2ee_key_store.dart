// Local persistence for E2EE state, in a drift database SEPARATE from the app's
// main FluxerDatabase — mirroring how web/RN keep E2EE in its own store. Holds
// the encrypted Olm account pickle, Olm/Megolm session pickles, the peer
// identity-key cache (rotation guard), and the decrypted-plaintext cache.
//
// The pickle KEY that encrypts these pickles does NOT live here — it lives in
// flutter_secure_storage (Keychain/Keystore), so the identity survives even if
// this cache-dir database is cleared. See e2ee_manager.dart.
//
// INVARIANT: this database is never auto-wiped on an open/migration error. A
// catch-all that drops and recreates it would destroy the identity, every
// session, and the plaintext cache — the exact bug that produced the web
// client's per-launch device churn.
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'e2ee_key_store.g.dart';

/// The single Olm account (this install's identity). One row, keyed by user id
/// so a re-login as a different user can't collide.
@DataClassName('StoredE2eeAccount')
class E2eeAccounts extends Table {
  TextColumn get userId => text()();
  TextColumn get deviceId => text()();
  TextColumn get accountPickle => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {userId};
}

/// Olm 1:1 sessions, keyed by the remote (user, device, session). Multiple
/// sessions can exist per remote device; the most-recently-used wins on encrypt.
@DataClassName('StoredOlmSession')
class E2eeOlmSessions extends Table {
  TextColumn get remoteUserId => text()();
  TextColumn get remoteDeviceId => text()();
  TextColumn get sessionId => text()();
  TextColumn get sessionPickle => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastUsedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {remoteUserId, remoteDeviceId, sessionId};
}

/// Our outbound Megolm session per group-DM channel (one active at a time). The
/// recipient-set hash lets us detect when the channel's device set changed and
/// rotate. (Phase 2.)
@DataClassName('StoredOutboundGroupSession')
class E2eeOutboundGroupSessions extends Table {
  TextColumn get channelId => text()();
  TextColumn get sessionId => text()();
  TextColumn get sessionPickle => text()();
  IntColumn get messageCount => integer().withDefault(const Constant(0))();
  TextColumn get recipientSetHash => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {channelId};
}

/// Inbound Megolm sessions we've received, keyed by (channel, sender device,
/// session). NEVER re-pickled after decrypt — that would advance the stored
/// ratchet past first_known_index and break history re-decrypt. (Phase 2.)
@DataClassName('StoredInboundGroupSession')
class E2eeInboundGroupSessions extends Table {
  TextColumn get channelId => text()();
  TextColumn get senderUserId => text()();
  TextColumn get senderDeviceId => text()();
  TextColumn get sessionId => text()();
  TextColumn get sessionPickle => text()();
  TextColumn get senderIdentityKey => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey =>
      {channelId, senderUserId, senderDeviceId, sessionId};
}

/// Last-seen published identity key per peer device. Compared before every
/// encrypt; a change means the peer rotated and we must drop their Olm sessions
/// so the next send rebuilds X3DH (prevents BAD_MESSAGE_MAC).
@DataClassName('StoredPeerIdentity')
class E2eePeerIdentities extends Table {
  TextColumn get peerUserId => text()();
  TextColumn get peerDeviceId => text()();
  TextColumn get identityKey => text()();

  @override
  Set<Column> get primaryKey => {peerUserId, peerDeviceId};
}

/// Manual device-verification records. A row means the local user confirmed
/// (out-of-band fingerprint comparison) that a peer device's published identity
/// key is genuine. Keyed by (remote user, remote device). The verified identity
/// key is captured so a later rotation reads as "changed — re-verify" rather
/// than silently staying "verified". Local trust only — never sent on the wire.
@DataClassName('StoredE2eeVerification')
class E2eeVerifications extends Table {
  TextColumn get remoteUserId => text()();
  TextColumn get remoteDeviceId => text()();
  TextColumn get identityKey => text()();
  DateTimeColumn get verifiedAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get source => text().withDefault(const Constant('manual'))();

  @override
  Set<Column> get primaryKey => {remoteUserId, remoteDeviceId};
}

/// Decrypted-plaintext cache. Olm/Megolm consume per-message material on
/// decrypt, so a re-fetched ciphertext can't be re-decrypted — this cache is the
/// only way to re-render encrypted history after a reload. Keyed by message id;
/// also indexed by channel for on-device search.
@DataClassName('StoredMessagePlaintext')
class E2eeMessagePlaintexts extends Table {
  TextColumn get messageId => text()();
  TextColumn get channelId => text().nullable()();
  TextColumn get plaintext => text()();
  TextColumn get verificationStatus => text().nullable()();
  /// JSON array of the decrypted attachment envelope entries ({key,iv,mime,name,
  /// ...}). Persisted because Olm/Megolm are single-use: after a reload the
  /// message envelope can't be re-decrypted, so without the per-file AES keys
  /// here, encrypted attachments would become permanently unopenable.
  TextColumn get attachmentsJson => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {messageId};
}

@DriftDatabase(
  tables: [
    E2eeAccounts,
    E2eeOlmSessions,
    E2eeOutboundGroupSessions,
    E2eeInboundGroupSessions,
    E2eePeerIdentities,
    E2eeVerifications,
    E2eeMessagePlaintexts,
  ],
)
class E2eeKeyStore extends _$E2eeKeyStore {
  E2eeKeyStore() : super(_open());

  /// Test/inject constructor.
  E2eeKeyStore.forTesting(super.e);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(
              e2eeMessagePlaintexts,
              e2eeMessagePlaintexts.attachmentsJson,
            );
          }
          if (from < 3) {
            await m.createTable(e2eeVerifications);
          }
        },
      );

  static QueryExecutor _open() => driftDatabase(name: 'fluxer_e2ee');

  // ── Account ──────────────────────────────────────────────────────────────

  Future<StoredE2eeAccount?> readAccount(String userId) =>
      (select(e2eeAccounts)..where((t) => t.userId.equals(userId)))
          .getSingleOrNull();

  Future<void> writeAccount(E2eeAccountsCompanion account) =>
      into(e2eeAccounts).insertOnConflictUpdate(account);

  Future<void> deleteAccount(String userId) =>
      (delete(e2eeAccounts)..where((t) => t.userId.equals(userId))).go();

  // ── Olm sessions ─────────────────────────────────────────────────────────

  /// All sessions for one remote device, most-recently-used first.
  Future<List<StoredOlmSession>> sessionsForDevice(
    String remoteUserId,
    String remoteDeviceId,
  ) =>
      (select(e2eeOlmSessions)
            ..where((t) =>
                t.remoteUserId.equals(remoteUserId) &
                t.remoteDeviceId.equals(remoteDeviceId))
            ..orderBy([(t) => OrderingTerm.desc(t.lastUsedAt)]))
          .get();

  /// Every stored Olm session (all peers/devices). Used to build a backup.
  Future<List<StoredOlmSession>> allOlmSessions() =>
      select(e2eeOlmSessions).get();

  Future<void> writeSession(E2eeOlmSessionsCompanion session) =>
      into(e2eeOlmSessions).insertOnConflictUpdate(session);

  Future<void> touchSession(
    String remoteUserId,
    String remoteDeviceId,
    String sessionId,
  ) =>
      (update(e2eeOlmSessions)
            ..where((t) =>
                t.remoteUserId.equals(remoteUserId) &
                t.remoteDeviceId.equals(remoteDeviceId) &
                t.sessionId.equals(sessionId)))
          .write(E2eeOlmSessionsCompanion(lastUsedAt: Value(DateTime.now())));

  /// Drop all Olm sessions with a peer device — used on identity-key rotation so
  /// the next send establishes a fresh X3DH session.
  Future<void> deleteSessionsForDevice(
    String remoteUserId,
    String remoteDeviceId,
  ) =>
      (delete(e2eeOlmSessions)
            ..where((t) =>
                t.remoteUserId.equals(remoteUserId) &
                t.remoteDeviceId.equals(remoteDeviceId)))
          .go();

  // ── Peer identity cache (rotation guard) ─────────────────────────────────

  Future<StoredPeerIdentity?> peerIdentity(
    String peerUserId,
    String peerDeviceId,
  ) =>
      (select(e2eePeerIdentities)
            ..where((t) =>
                t.peerUserId.equals(peerUserId) &
                t.peerDeviceId.equals(peerDeviceId)))
          .getSingleOrNull();

  Future<void> writePeerIdentity(E2eePeerIdentitiesCompanion identity) =>
      into(e2eePeerIdentities).insertOnConflictUpdate(identity);

  // ── Device verifications (Phase 3c) ──────────────────────────────────────

  Future<StoredE2eeVerification?> readVerification(
    String remoteUserId,
    String remoteDeviceId,
  ) =>
      (select(e2eeVerifications)
            ..where((t) =>
                t.remoteUserId.equals(remoteUserId) &
                t.remoteDeviceId.equals(remoteDeviceId)))
          .getSingleOrNull();

  Future<List<StoredE2eeVerification>> verificationsForUser(
    String remoteUserId,
  ) =>
      (select(e2eeVerifications)
            ..where((t) => t.remoteUserId.equals(remoteUserId)))
          .get();

  /// Every stored verification (all peers). Used to build a backup.
  Future<List<StoredE2eeVerification>> allVerifications() =>
      select(e2eeVerifications).get();

  Future<void> writeVerification(E2eeVerificationsCompanion verification) =>
      into(e2eeVerifications).insertOnConflictUpdate(verification);

  Future<void> deleteVerification(
    String remoteUserId,
    String remoteDeviceId,
  ) =>
      (delete(e2eeVerifications)
            ..where((t) =>
                t.remoteUserId.equals(remoteUserId) &
                t.remoteDeviceId.equals(remoteDeviceId)))
          .go();

  // ── Plaintext cache ──────────────────────────────────────────────────────

  Future<StoredMessagePlaintext?> readPlaintext(String messageId) =>
      (select(e2eeMessagePlaintexts)
            ..where((t) => t.messageId.equals(messageId)))
          .getSingleOrNull();

  Future<void> writePlaintext(E2eeMessagePlaintextsCompanion entry) =>
      into(e2eeMessagePlaintexts).insertOnConflictUpdate(entry);

  Future<void> deletePlaintexts(List<String> messageIds) =>
      (delete(e2eeMessagePlaintexts)..where((t) => t.messageId.isIn(messageIds)))
          .go();

  // ── Outbound group (Megolm) sessions ─────────────────────────────────────

  Future<StoredOutboundGroupSession?> readOutboundGroupSession(
    String channelId,
  ) =>
      (select(e2eeOutboundGroupSessions)
            ..where((t) => t.channelId.equals(channelId)))
          .getSingleOrNull();

  Future<void> writeOutboundGroupSession(
    E2eeOutboundGroupSessionsCompanion session,
  ) =>
      into(e2eeOutboundGroupSessions).insertOnConflictUpdate(session);

  Future<void> deleteOutboundGroupSession(String channelId) =>
      (delete(e2eeOutboundGroupSessions)
            ..where((t) => t.channelId.equals(channelId)))
          .go();

  // ── Inbound group (Megolm) sessions ──────────────────────────────────────

  Future<StoredInboundGroupSession?> readInboundGroupSession(
    String channelId,
    String senderUserId,
    String senderDeviceId,
    String sessionId,
  ) =>
      (select(e2eeInboundGroupSessions)
            ..where((t) =>
                t.channelId.equals(channelId) &
                t.senderUserId.equals(senderUserId) &
                t.senderDeviceId.equals(senderDeviceId) &
                t.sessionId.equals(sessionId)))
          .getSingleOrNull();

  /// Persist a NEW inbound group session. Uses insert-if-absent (NOT
  /// insertOnConflictUpdate): an already-imported session must never be
  /// overwritten with a higher first-known-index copy, which would lose the
  /// ability to decrypt earlier history.
  /// Every stored inbound group session. Used to build a backup.
  Future<List<StoredInboundGroupSession>> allInboundGroupSessions() =>
      select(e2eeInboundGroupSessions).get();

  Future<void> writeInboundGroupSessionIfAbsent(
    E2eeInboundGroupSessionsCompanion session,
  ) =>
      into(e2eeInboundGroupSessions).insert(session, mode: InsertMode.insertOrIgnore);

  /// Drop an inbound group session — used only to evict a corrupt/unreadable
  /// pickle so a re-import can replace it.
  Future<void> deleteInboundGroupSession(
    String channelId,
    String senderUserId,
    String senderDeviceId,
    String sessionId,
  ) =>
      (delete(e2eeInboundGroupSessions)
            ..where((t) =>
                t.channelId.equals(channelId) &
                t.senderUserId.equals(senderUserId) &
                t.senderDeviceId.equals(senderDeviceId) &
                t.sessionId.equals(sessionId)))
          .go();

  /// Wipe every store — called on logout so a different user signing in on the
  /// same install can't be linked to the previous user's material.
  Future<void> wipeAll() => transaction(() async {
        await delete(e2eeAccounts).go();
        await delete(e2eeOlmSessions).go();
        await delete(e2eeOutboundGroupSessions).go();
        await delete(e2eeInboundGroupSessions).go();
        await delete(e2eePeerIdentities).go();
        await delete(e2eeVerifications).go();
        await delete(e2eeMessagePlaintexts).go();
      });
}
