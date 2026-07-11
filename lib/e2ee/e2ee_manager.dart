// The E2EE orchestrator: the one place that composes the crypto primitives
// (e2ee_crypto), local persistence (e2ee_key_store), durable identity
// (e2ee_secure_store) and the server (e2ee_api) into the actual protocol. It is
// the third implementation of this protocol after the web (/opt/fluxer) and
// React Native (fluxer-mobile) clients; the wire and crypto are byte-compatible
// with both (verified by the crate + Dart-VM interop spikes). Where this file
// deliberately DIVERGES from those two references, it is to fix a known bug in
// them — each such spot is called out inline with an "IMPROVEMENT:" note.
//
// Threading model: all methods are async and assume single-flighted use from
// the UI isolate. Bootstrap is de-duplicated and back-off throttled internally.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:fluxer_app/e2ee/e2ee_api.dart';
import 'package:fluxer_app/e2ee/e2ee_crypto.dart';
import 'package:fluxer_app/e2ee/e2ee_key_store.dart';
import 'package:fluxer_app/e2ee/e2ee_secure_store.dart';
import 'package:fluxer_app/e2ee/e2ee_wire.dart';

/// One-time-key pool sizing, matching web/RN exactly (cross-client parity of
/// pool behaviour, not of the wire, but kept identical to reason about jointly).
const int kOneTimeKeyBatchSize = 50;

/// Replenish the server-side one-time-key pool when the unclaimed count drops to
/// this or below. Web inlines the literal `> 10`; we use the named constant.
const int kReplenishThreshold = 10;

/// Post-send replenish check throttle, and bootstrap-failure back-off. Matches
/// web's REPLENISH_INTERVAL_MS (5 min) and BOOTSTRAP_RETRY_MIN_MS (30 s).
const Duration kReplenishInterval = Duration(minutes: 5);
const Duration kBootstrapRetryMin = Duration(seconds: 30);

/// Registration lifecycle, surfaced to the UI for the E2EE status indicator.
enum E2eeRegistrationStatus { idle, initialising, registering, ready, error }

/// The outcome of a decrypt attempt.
///
/// IMPROVEMENT over web/RN: those collapse EVERY 1:1 failure to a permanent
/// "🔒 unreadable" state — including a normal (type-1) message that simply
/// arrived before its session-establishing pre-key message. That ordering case
/// is recoverable and is a likely cause of the "this message is encrypted"
/// reports. Here it is [DecryptionTransient] (retryable); only genuinely
/// unrecoverable conditions are [DecryptionPermanent].
sealed class DecryptionOutcome {
  const DecryptionOutcome();
}

class DecryptionOk extends DecryptionOutcome {
  const DecryptionOk({
    required this.text,
    this.attachments = const [],
    this.verificationStatus = 'unverified',
  });

  final String text;
  final List<Map<String, Object?>> attachments;
  final String verificationStatus;
}

/// Retryable: the message may decrypt on a later attempt (not yet bootstrapped,
/// a normal message ahead of its pre-key message, or a transient network error
/// on the group path). Callers should retry with a bounded budget, NOT cache a
/// failure.
class DecryptionTransient extends DecryptionOutcome {
  const DecryptionTransient(this.reason);
  final String reason;
}

/// Terminal: this device can never decrypt this message (not addressed to us,
/// malformed, or a MAC failure on an established session). Safe to render a
/// permanent placeholder and never retry.
class DecryptionPermanent extends DecryptionOutcome {
  const DecryptionPermanent(this.reason);
  final String reason;
}

/// Thrown internally by the low-level 1:1 decrypt to signal the recoverable
/// "normal message with no established session yet" ordering case.
class _TransientOrderingException implements Exception {
  const _TransientOrderingException();
}

/// Outcome of trying to fetch + import the Megolm session-key blobs for a
/// channel: [imported] the target session is now available, [noBlob] none was
/// addressed to this device (pre-join / forward-secrecy — permanent), or
/// [networkError] the listing failed (retryable).
enum _GroupImportResult { imported, noBlob, networkError }

class _SentPlaintext {
  const _SentPlaintext(this.text, this.attachments);
  final String text;
  final List<Map<String, Object?>> attachments;
}

/// One recipient device we are fanning an Olm ciphertext out to.
class _Target {
  const _Target(this.userId, this.device, this.claim);
  final String userId;
  final E2eeDeviceInfo device;
  final E2eePrekeyBundle? claim;
}

class E2eeManager {
  E2eeManager({
    required E2eeApi api,
    required E2eeKeyStore store,
    required E2eeSecureStore secure,
    DateTime Function()? now,
    Random? random,
  })  : _api = api,
        _store = store,
        _secure = secure,
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  final E2eeApi _api;
  final E2eeKeyStore _store;
  final E2eeSecureStore _secure;
  final DateTime Function() _now;
  final Random _random;

  // ── In-memory session state (established at bootstrap) ─────────────────────
  E2eeAccount? _account;
  String? _accountUserId;
  String? _deviceId;
  Uint8List? _pickleKey;

  E2eeRegistrationStatus _status = E2eeRegistrationStatus.idle;
  String? _lastError;

  E2eeRegistrationStatus get status => _status;
  String? get lastError => _lastError;
  String? get deviceId => _deviceId;
  bool get isReady => _status == E2eeRegistrationStatus.ready && _account != null;

  // ── Bootstrap de-dup / back-off ────────────────────────────────────────────
  Future<void>? _bootstrapFuture;
  String? _bootstrapUserId;
  DateTime? _lastBootstrapFailureAt;

  // ── Replenish throttle ─────────────────────────────────────────────────────
  DateTime? _lastReplenishAt;
  bool _replenishInflight = false;

  // ── Own-message plaintext caches (own current device has no self-slot) ──────
  final Map<String, _SentPlaintext> _sentByMessageId = <String, _SentPlaintext>{};
  final Map<String, _SentPlaintext> _sentByNonce = <String, _SentPlaintext>{};

  // ───────────────────────────────────────────────────────────────────────────
  // Bootstrap
  // ───────────────────────────────────────────────────────────────────────────

  /// Ensure this install has a registered device for [userId]. Safe (and cheap)
  /// to call on every gateway READY: concurrent/duplicate calls share one
  /// in-flight future, and a recent failure is backed off rather than retried
  /// in a tight loop.
  Future<void> ensureBootstrapped(String userId) {
    final inflight = _bootstrapFuture;
    if (inflight != null && _bootstrapUserId == userId) {
      return inflight;
    }
    if (_bootstrapUserId == userId &&
        _status == E2eeRegistrationStatus.error &&
        _lastBootstrapFailureAt != null &&
        _now().difference(_lastBootstrapFailureAt!) < kBootstrapRetryMin) {
      return Future<void>.value();
    }

    final future = _doBootstrap(userId);
    _bootstrapUserId = userId;
    _bootstrapFuture = future.then<void>((_) {
      // Keep the RESOLVED future cached (do NOT null it). Subsequent same-user
      // READYs then short-circuit on the in-flight guard above instead of
      // re-running _doBootstrap — which would flap _status to `initialising`,
      // drop isReady to false, and open a window where a send silently
      // downgrades to plaintext (and swap the live _account, racing an in-flight
      // decrypt). Once ready we stay ready. Ongoing server reconciliation + OTK
      // top-up run via scheduleReplenishCheck, which fires after every send and
      // every decrypt and on each gateway READY (see [onGatewayReady]) — so it
      // no longer depends on re-running bootstrap. Cleared only on error (below)
      // and on logout/account switch.
    }, onError: (Object error, StackTrace stack) {
      _status = E2eeRegistrationStatus.error;
      _lastError = error.toString();
      _lastBootstrapFailureAt = _now();
      // Clear so the next READY builds a fresh attempt instead of returning the
      // rejected future (a single blip must not wedge E2EE until app restart).
      _bootstrapFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
    return _bootstrapFuture!;
  }

  /// The gateway integration point: call on every READY/reconnect. It ensures
  /// bootstrap has run once, then — if already ready — fires the throttled
  /// server reconcile (OTK top-up + device-gone detection) WITHOUT re-running
  /// bootstrap, so the ready state and the live account are never disturbed.
  /// This keeps reconciliation alive for a long-lived session that stays
  /// connected and never sends.
  Future<void> onGatewayReady(String userId) async {
    await ensureBootstrapped(userId);
    scheduleReplenishCheck();
  }

  Future<void> _doBootstrap(String userId) async {
    _status = E2eeRegistrationStatus.initialising;
    _lastError = null;
    await initE2eeCrypto();

    final pickleKey = await _secure.readPickleKey(userId);
    final breadcrumbDeviceId = await _secure.readDeviceId(userId);

    // INVARIANT: a storage READ error is NEVER treated as "no account". We let
    // it propagate (bootstrap fails transient, the next READY retries) instead
    // of catching it and falling through to registration — swallowing it would
    // silently mint a new identity on a transient failure (the web openDB-wipe
    // bug that caused per-launch device churn).
    final row = await _store.readAccount(userId);

    if (row != null && pickleKey != null) {
      // A pickle present but unreadable (corruption / key mismatch) throws here
      // and propagates for the same reason — it is a load error, not a clean
      // miss, so we must NOT re-mint.
      final account = E2eeAccount.fromPickle(row.accountPickle, pickleKey);
      // STATE B — load existing.
      _account = account;
      _accountUserId = userId;
      _deviceId = row.deviceId;
      _pickleKey = pickleKey;
      _status = E2eeRegistrationStatus.ready;
      // Reconcile against the server + replenish, best-effort, off the hot path.
      // Routed through the throttle so a following onGatewayReady doesn't
      // double-reconcile at startup.
      scheduleReplenishCheck();
      return;
    }

    // No account row (a clean miss).
    if (breadcrumbDeviceId != null) {
      // STATE C — cache lost but we registered before. The private keys are gone
      // and unrecoverable (Phase 3 will attempt an encrypted-backup restore
      // here first). GC the orphaned server device, then register a fresh one.
      await _registerFreshDevice(userId, orphanDeviceId: breadcrumbDeviceId);
      return;
    }

    // STATE A — genuine first run.
    await _registerFreshDevice(userId);
  }

  Future<void> _registerFreshDevice(String userId, {String? orphanDeviceId}) async {
    _status = E2eeRegistrationStatus.registering;

    final account = E2eeAccount.create();
    final deviceId = _generateDeviceId();
    final pickleKey = _generatePickleKey();
    final signedPrekey = _buildSelfSignedPrekey(account);
    final registrationId =
        deriveRegistrationId(account.identityKey, account.ed25519Key);
    final oneTimePrekeys = _generateOneTimePrekeys(account);

    // Persist locally BEFORE the POST. If the POST then fails we keep a fully
    // recoverable local identity, and reconciliation re-publishes THIS SAME
    // identity (see _reconcileAndReplenish) rather than minting another one —
    // eliminating the churn both references suffer on a failed registration.
    await _secure.writePickleKey(userId, pickleKey);
    await _store.writeAccount(
      E2eeAccountsCompanion.insert(
        userId: userId,
        deviceId: deviceId,
        accountPickle: account.toPickle(pickleKey),
      ),
    );
    await _secure.writeDeviceId(userId, deviceId);

    _account = account;
    _accountUserId = userId;
    _deviceId = deviceId;
    _pickleKey = pickleKey;

    // GC the orphan (STATE C) before claiming the new identity. Best-effort:
    // DELETE of an unknown device is a 200 no-op server-side.
    if (orphanDeviceId != null && orphanDeviceId != deviceId) {
      try {
        await _api.deleteDevice(orphanDeviceId);
      } on Object catch (_) {
        // A leftover orphan is harmless (extra fan-out target that yields no
        // slot); never block registration on its cleanup.
      }
    }

    await _api.registerDevice(
      deviceId: deviceId,
      identityKey: account.identityKey,
      registrationId: registrationId,
      signedPrekey: signedPrekey,
      oneTimePrekeys: oneTimePrekeys,
      deviceName: _detectDeviceName(),
    );

    _status = E2eeRegistrationStatus.ready;
  }

  /// Re-publish the CURRENTLY LOADED identity (same device id, identity key and
  /// signed prekey) with a fresh batch of one-time keys. Used when the server
  /// has forgotten our device but we still hold the private keys locally — the
  /// no-churn recovery path.
  Future<void> _publishExistingIdentity(String userId) async {
    final account = _account;
    final deviceId = _deviceId;
    final pickleKey = _pickleKey;
    if (account == null || deviceId == null || pickleKey == null) {
      return;
    }
    final signedPrekey = _buildSelfSignedPrekey(account);
    final registrationId =
        deriveRegistrationId(account.identityKey, account.ed25519Key);
    final oneTimePrekeys = _generateOneTimePrekeys(account);
    // Persist the consumed/published account state before the POST.
    await _store.writeAccount(
      E2eeAccountsCompanion.insert(
        userId: userId,
        deviceId: deviceId,
        accountPickle: account.toPickle(pickleKey),
      ),
    );
    await _api.registerDevice(
      deviceId: deviceId,
      identityKey: account.identityKey,
      registrationId: registrationId,
      signedPrekey: signedPrekey,
      oneTimePrekeys: oneTimePrekeys,
      deviceName: _detectDeviceName(),
    );
  }

  /// After a load-existing bootstrap: confirm the server still lists our device
  /// (else re-publish the same identity), and top up one-time keys if low.
  Future<void> _reconcileAndReplenish(String userId) async {
    List<E2eeDeviceInfo> devices;
    try {
      devices = await _api.listOwnDevices();
    } on Object catch (_) {
      return; // transient; the next boot reconciles again
    }
    E2eeDeviceInfo? ours;
    for (final d in devices) {
      if (d.deviceId == _deviceId) {
        ours = d;
        break;
      }
    }
    if (ours == null) {
      // Server forgot us (deleted elsewhere / GC). Re-publish the SAME identity
      // — never re-mint while we still hold the private keys.
      try {
        await _publishExistingIdentity(userId);
      } on Object catch (_) {
        // best-effort; retried next boot
      }
      return;
    }
    final count = ours.oneTimePrekeyCount;
    if (count != null && count <= kReplenishThreshold) {
      await _replenishOneTimeKeys();
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // One-time-key replenishment (RN has NONE — this closes that gap)
  // ───────────────────────────────────────────────────────────────────────────

  /// Throttled post-send check. Fire-and-forget from the encrypt path.
  void scheduleReplenishCheck() {
    if (_replenishInflight) {
      return;
    }
    final last = _lastReplenishAt;
    if (last != null && _now().difference(last) < kReplenishInterval) {
      return;
    }
    _lastReplenishAt = _now();
    _replenishInflight = true;
    unawaited(() async {
      try {
        final userId = _accountUserId;
        if (userId != null) {
          await _reconcileAndReplenish(userId);
        }
      } finally {
        _replenishInflight = false;
      }
    }());
  }

  Future<void> _replenishOneTimeKeys() async {
    final account = _account;
    final deviceId = _deviceId;
    final pickleKey = _pickleKey;
    final userId = _accountUserId;
    if (account == null || deviceId == null || pickleKey == null || userId == null) {
      return;
    }
    final fresh = _generateOneTimePrekeys(account);
    // Persist the published account state before the POST so the marked-as-
    // published keys are not resurfaced by a later generate call.
    await _store.writeAccount(
      E2eeAccountsCompanion.insert(
        userId: userId,
        deviceId: deviceId,
        accountPickle: account.toPickle(pickleKey),
      ),
    );
    try {
      await _api.topUpOneTimePrekeys(deviceId, fresh);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        // Device unknown to the server — re-publish the same identity.
        await _publishExistingIdentity(userId);
      }
      // other errors: retried on a later scheduled check
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Encrypt (1:1 DM). Group DM is Phase 2.
  // ───────────────────────────────────────────────────────────────────────────

  /// Build the `encrypted_payload` for a message, or null to fall back to
  /// plaintext (unsupported channel type, not bootstrapped, no reachable
  /// recipient device, etc.). Never returns a black-hole payload.
  Future<Map<String, Object?>?> tryEncryptForChannel({
    required int channelType,
    required List<String> recipientUserIds,
    required String plaintext,
    List<Map<String, Object?>> attachments = const [],
  }) async {
    final account = _account;
    final ownDeviceId = _deviceId;
    final selfUserId = _accountUserId;
    final pickleKey = _pickleKey;
    if (!isReady ||
        account == null ||
        ownDeviceId == null ||
        selfUserId == null ||
        pickleKey == null) {
      return null;
    }
    if (!isEncryptedChannelType(channelType)) {
      return null;
    }
    if (channelType == kChannelTypeGroupDm) {
      return null; // Megolm — Phase 2
    }

    final peers = recipientUserIds.where((id) => id != selfUserId).toList();
    if (peers.length != 1) {
      return null;
    }
    final peerId = peers.first;

    final List<E2eeDeviceInfo> peerDevices;
    final List<E2eeDeviceInfo> ownDevices;
    try {
      final results = await Future.wait<List<E2eeDeviceInfo>>([
        _api.listPublicDevices(peerId),
        _api.listPublicDevices(selfUserId),
      ]);
      peerDevices = results[0];
      ownDevices = results[1];
    } on Object catch (_) {
      return null;
    }
    if (peerDevices.isEmpty) {
      return null;
    }

    // The fan-out device set: every peer device plus our OTHER devices.
    // IMPROVEMENT: exclude our OWN CURRENT device. Web and RN both encrypt a
    // redundant self-slot to the sending device (it can't read its own outbound
    // session anyway — own messages render from the plaintext cache), needlessly
    // burning one of our own one-time keys per send. We still fan out to our
    // OTHER devices so multi-device self-read works.
    final fanoutDevices = <(String, E2eeDeviceInfo)>[
      for (final d in peerDevices) (peerId, d),
      for (final d in ownDevices)
        if (d.deviceId != ownDeviceId) (selfUserId, d),
    ];

    // Rotation guard BEFORE claim-avoidance: if a peer rotated its identity key
    // we drop the now-dead Olm session here, so the claim-avoidance check below
    // sees that device as session-less and re-claims in THIS send. (Running the
    // guard after the claim decision — as web does — would leave the rotated
    // device with neither a session nor a claim, silently dropping it from one
    // message before it recovers on the next send.)
    await _applyRotationGuard(fanoutDevices);

    // Claim-avoidance: only spend a claim round-trip (which burns a peer OTK)
    // for a side that has at least one device without a stored Olm session.
    final needClaimPeer = await _anyDeviceWithoutSession(peerId, peerDevices);
    final needClaimSelf = await _anyDeviceWithoutSession(selfUserId, ownDevices);
    final claims = <String, E2eePrekeyBundle>{};
    try {
      if (needClaimPeer) {
        claims.addAll(await _claimFor(peerId));
      }
      if (needClaimSelf) {
        claims.addAll(await _claimFor(selfUserId));
      }
    } on Object catch (_) {
      return null;
    }

    final targets = <_Target>[
      for (final (userId, device) in fanoutDevices)
        _Target(userId, device, claims['$userId:${device.deviceId}']),
    ];

    final envelope =
        PlaintextEnvelope(text: plaintext, attachments: attachments).encode();

    final ciphertexts = <String, OlmCiphertext>{};
    for (final t in targets) {
      try {
        final session = await _loadOrCreateOutboundSession(t, pickleKey);
        final enc = session.encrypt(envelope);
        ciphertexts[olmSlotKey(t.userId, t.device.deviceId)] =
            OlmCiphertext(type: enc.type, body: enc.body);
        await _store.writeSession(
          E2eeOlmSessionsCompanion.insert(
            remoteUserId: t.userId,
            remoteDeviceId: t.device.deviceId,
            sessionId: session.sessionId,
            sessionPickle: session.toPickle(pickleKey),
            lastUsedAt: Value(_now()),
          ),
        );
      } on Object catch (_) {
        // Unreachable device (no session, no claimable OTK): skip its slot.
      }
    }

    if (ciphertexts.isEmpty) {
      return null;
    }

    scheduleReplenishCheck();

    return OlmPayload(
      senderDeviceId: ownDeviceId,
      senderIdentityKey: account.identityKey,
      ciphertexts: ciphertexts,
    ).toJson();
  }

  /// Record our own sent plaintext so our echo renders. [nonce] covers the
  /// window before the server assigns [messageId]; the messageId entry is also
  /// persisted so our own message survives a reload (our current device has no
  /// decryptable ciphertext slot of its own).
  void recordSentPlaintext({
    required String text,
    String? messageId,
    String? nonce,
    String? channelId,
    List<Map<String, Object?>> attachments = const [],
  }) {
    final entry = _SentPlaintext(text, attachments);
    if (nonce != null) {
      _sentByNonce[nonce] = entry;
    }
    if (messageId != null) {
      _sentByMessageId[messageId] = entry;
      unawaited(_store
          .writePlaintext(_plaintextRow(messageId, channelId, text, 'verified'))
          .catchError((Object _) {}));
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Decrypt
  // ───────────────────────────────────────────────────────────────────────────

  /// Decrypt an inbound message for the current device. [channelId] is required
  /// for the group path; [messageId]/[nonce] enable the plaintext caches.
  Future<DecryptionOutcome> tryDecryptForCurrentDevice({
    required String senderUserId,
    required Object? encryptedPayloadRaw,
    String? channelId,
    String? messageId,
    String? nonce,
  }) async {
    // 1. Persistent plaintext cache — checked BEFORE the ready gate so history
    // re-renders during a cold start (Olm/Megolm consume per-message material,
    // so a re-fetched ciphertext can never be decrypted a second time).
    if (messageId != null) {
      try {
        final cached = await _store.readPlaintext(messageId);
        if (cached != null) {
          return DecryptionOk(
            text: cached.plaintext,
            verificationStatus: cached.verificationStatus ?? 'unverified',
          );
        }
      } on Object catch (_) {
        // fall through
      }
    }

    // 2. Own-message in-memory caches (the echo of a message we just sent).
    if (senderUserId == _accountUserId) {
      final sent = (messageId != null ? _sentByMessageId[messageId] : null) ??
          (nonce != null ? _sentByNonce[nonce] : null);
      if (sent != null) {
        return DecryptionOk(
          text: sent.text,
          attachments: sent.attachments,
          verificationStatus: 'verified',
        );
      }
    }

    final payload = EncryptedPayload.tryParse(encryptedPayloadRaw);
    if (payload == null) {
      return const DecryptionPermanent('no encrypted payload');
    }

    // 3. Not bootstrapped yet — TRANSIENT (self-heals once ready), not permanent.
    if (!isReady || _deviceId == null || _pickleKey == null) {
      return const DecryptionTransient('not bootstrapped');
    }

    if (payload is MegolmPayload) {
      if (channelId == null) {
        return const DecryptionPermanent('group message without a channel id');
      }
      return _decryptMegolm(
        payload: payload,
        channelId: channelId,
        senderUserId: senderUserId,
        messageId: messageId,
      );
    }

    final olm = payload as OlmPayload;
    final slot = olm.ciphertexts[olmSlotKey(_accountUserId!, _deviceId!)];
    if (slot == null) {
      // No ciphertext addressed to this device: it was sent before this device
      // existed, or to a different device. Never decryptable here.
      return const DecryptionPermanent('not addressed to this device');
    }

    try {
      final decrypted = await _olmDecrypt(
        remoteUserId: senderUserId,
        remoteDeviceId: olm.senderDeviceId,
        remoteIdentityKey: olm.senderIdentityKey,
        ciphertext: slot,
      );
      final env = PlaintextEnvelope.decode(decrypted);
      if (messageId != null) {
        try {
          await _store.writePlaintext(
            _plaintextRow(messageId, channelId, env.text, 'unverified'),
          );
        } on Object catch (_) {
          // caching is best-effort
        }
      }
      // A received message may have established an inbound session, consuming one
      // of our one-time keys. Fire the throttled reconcile so a RECEIVE-ONLY
      // long-lived session still replenishes its OTK pool and detects a
      // server-side device deletion (it would otherwise only run after a send).
      scheduleReplenishCheck();
      return DecryptionOk(text: env.text, attachments: env.attachments);
    } on _TransientOrderingException {
      return const DecryptionTransient('normal message ahead of its pre-key');
    } on Object catch (error) {
      // A pre-key we cannot process, or a MAC failure on an established session:
      // unrecoverable for this device.
      return DecryptionPermanent('olm decrypt failed: $error');
    }
  }

  /// Low-level 1:1 decrypt. Tries every stored session for the sender device,
  /// then (for a pre-key message) establishes a new inbound session, persisting
  /// the consumed one-time-key account state. Throws
  /// [_TransientOrderingException] only when NO session exists yet for a normal
  /// message (a recoverable ordering gap).
  Future<String> _olmDecrypt({
    required String remoteUserId,
    required String remoteDeviceId,
    required String remoteIdentityKey,
    required OlmCiphertext ciphertext,
  }) async {
    final account = _account!;
    final pickleKey = _pickleKey!;
    final userId = _accountUserId!;
    final ownDeviceId = _deviceId!;
    final type = ciphertext.type == kOlmMessageTypeNormal
        ? kOlmMessageTypeNormal
        : kOlmMessageTypePreKey;

    final stored = await _store.sessionsForDevice(remoteUserId, remoteDeviceId);
    for (final s in stored) {
      final E2eeOlmSession session;
      try {
        session = E2eeOlmSession.fromPickle(s.sessionPickle, pickleKey);
      } on Object catch (_) {
        continue; // unreadable pickle — skip this session
      }
      final String text;
      try {
        text = session.decrypt(type: type, body: ciphertext.body);
      } on Object catch (_) {
        continue; // this session can't read this message — try the next
      }
      // Decrypted. Persist the advanced ratchet best-effort: a storage hiccup
      // must never turn an already-recovered plaintext into a lost message.
      try {
        await _store.writeSession(
          E2eeOlmSessionsCompanion.insert(
            remoteUserId: remoteUserId,
            remoteDeviceId: remoteDeviceId,
            sessionId: session.sessionId,
            sessionPickle: session.toPickle(pickleKey),
            lastUsedAt: Value(_now()),
          ),
        );
      } on Object catch (_) {
        // best-effort
      }
      return text;
    }

    if (type != kOlmMessageTypePreKey) {
      if (stored.isEmpty) {
        // No session exists for this device yet — the establishing pre-key
        // message has not been processed. Genuinely recoverable ordering case.
        throw const _TransientOrderingException();
      }
      // We hold session(s) with this device but none can read this normal
      // message: corruption, or a message past the ratchet window. Unrecoverable
      // (a caller must not retry forever). A rare rotate-then-reorder could in
      // theory recover once the new session's pre-key lands, but 1:1 has no
      // fetch-retry and web/RN treat this as permanent too.
      throw StateError(
        'normal message readable by none of ${stored.length} stored sessions',
      );
    }

    // Establish a new inbound session from the pre-key message. vodozemac
    // consumes the matching one-time key on success; if establishment itself
    // throws it propagates (→ permanent), which is correct for a pre-key we
    // cannot process.
    final result = account.createInboundSession(
      theirIdentityKey: remoteIdentityKey,
      preKeyMessageBase64: ciphertext.body,
    );
    // Persist the consumed-OTK account state + new session best-effort. The
    // message is already decrypted; do not lose it to a durable-write failure.
    try {
      await _store.writeAccount(
        E2eeAccountsCompanion.insert(
          userId: userId,
          deviceId: ownDeviceId,
          accountPickle: account.toPickle(pickleKey),
        ),
      );
      await _store.writeSession(
        E2eeOlmSessionsCompanion.insert(
          remoteUserId: remoteUserId,
          remoteDeviceId: remoteDeviceId,
          sessionId: result.session.sessionId,
          sessionPickle: result.session.toPickle(pickleKey),
          lastUsedAt: Value(_now()),
        ),
      );
    } on Object catch (_) {
      // best-effort
    }
    return result.plaintext;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Group DM (Megolm) decrypt
  // ───────────────────────────────────────────────────────────────────────────

  Future<DecryptionOutcome> _decryptMegolm({
    required MegolmPayload payload,
    required String channelId,
    required String senderUserId,
    String? messageId,
  }) async {
    // 1. Try an already-imported inbound session for (channel, sender, session).
    final existing = await _store.readInboundGroupSession(
      channelId,
      senderUserId,
      payload.senderDeviceId,
      payload.sessionId,
    );
    if (existing != null) {
      final text = _tryMegolmDecrypt(existing, payload.ciphertext);
      if (text != null) {
        return _finishMegolm(text, channelId, messageId);
      }
      // A stored session that can't read this ciphertext is corrupt/tampered or
      // past its window — unrecoverable for this device.
      return const DecryptionPermanent(
        'megolm decrypt failed on stored session',
      );
    }

    // 2. No session yet — fetch + import the distributed session-key blobs.
    final result = await _fetchAndImportGroupSessions(
      channelId: channelId,
      senderUserId: senderUserId,
      payload: payload,
    );
    if (result == _GroupImportResult.networkError) {
      return const DecryptionTransient('group session listing failed');
    }
    if (result == _GroupImportResult.noBlob) {
      // No key blob targets this device (joined after the message, or forward
      // secrecy) — never decryptable here.
      return const DecryptionPermanent('no group session key for this device');
    }

    // 3. Imported — decrypt.
    final imported = await _store.readInboundGroupSession(
      channelId,
      senderUserId,
      payload.senderDeviceId,
      payload.sessionId,
    );
    if (imported == null) {
      return const DecryptionTransient('group session missing after import');
    }
    final text = _tryMegolmDecrypt(imported, payload.ciphertext);
    if (text == null) {
      return const DecryptionTransient('megolm decrypt failed after import');
    }
    return _finishMegolm(text, channelId, messageId);
  }

  /// Decrypt a Megolm ciphertext with a stored inbound session WITHOUT
  /// re-pickling it: the stored session must stay at its first-known index so
  /// earlier history can still be re-derived. Returns null on failure.
  String? _tryMegolmDecrypt(
    StoredInboundGroupSession stored,
    String ciphertext,
  ) {
    try {
      final session = E2eeInboundGroupSession.fromPickle(
        stored.sessionPickle,
        _pickleKey!,
      );
      return session.decrypt(ciphertext).plaintext;
    } on Object catch (_) {
      return null;
    }
  }

  Future<DecryptionOutcome> _finishMegolm(
    String decrypted,
    String channelId,
    String? messageId,
  ) async {
    final env = PlaintextEnvelope.decode(decrypted);
    if (messageId != null) {
      try {
        await _store.writePlaintext(
          _plaintextRow(messageId, channelId, env.text, 'unverified'),
        );
      } on Object catch (_) {
        // best-effort
      }
    }
    return DecryptionOk(text: env.text, attachments: env.attachments);
  }

  /// List the channel's pending Megolm session-key blobs, Olm-decrypt any
  /// addressed to this device, and import the enclosed session keys. Returns
  /// whether the specific target (sender device + session id) became available.
  Future<_GroupImportResult> _fetchAndImportGroupSessions({
    required String channelId,
    required String senderUserId,
    required MegolmPayload payload,
  }) async {
    final ownDeviceId = _deviceId!;
    final List<E2eeGroupSessionBlobIn> blobs;
    try {
      blobs = await _api.listGroupSessions(channelId);
    } on Object catch (_) {
      return _GroupImportResult.networkError;
    }

    var importedTarget = false;
    for (final blob in blobs) {
      if (blob.recipientDeviceId != ownDeviceId) {
        continue;
      }
      try {
        // The blob is an Olm message from the sender wrapping the session key.
        final keyJson = await _olmDecrypt(
          remoteUserId: blob.senderUserId,
          remoteDeviceId: blob.senderDeviceId,
          remoteIdentityKey: blob.senderIdentityKey,
          ciphertext: OlmCiphertext(
            type: blob.olmMessageType,
            body: blob.olmCiphertext,
          ),
        );
        final decoded = jsonDecode(keyJson);
        if (decoded is! Map) {
          continue;
        }
        final map = decoded.cast<String, Object?>();
        final sessionKey = map['session_key'];
        if (sessionKey is! String ||
            map['channel_id']?.toString() != channelId) {
          continue;
        }
        final inbound = E2eeInboundGroupSession.fromSessionKey(sessionKey);
        // Insert-if-absent so a re-delivered key can't overwrite (and advance) a
        // session we already hold at a lower index.
        await _store.writeInboundGroupSessionIfAbsent(
          E2eeInboundGroupSessionsCompanion.insert(
            channelId: channelId,
            senderUserId: blob.senderUserId,
            senderDeviceId: blob.senderDeviceId,
            sessionId: inbound.sessionId,
            sessionPickle: inbound.toPickle(_pickleKey!),
            senderIdentityKey: blob.senderIdentityKey,
          ),
        );
        // Best-effort GC of the consumed blob (idempotent; a failed ack just
        // re-imports the same key next time).
        unawaited(
          _api
              .ackGroupSessionBlob(
                channelId: channelId,
                sessionId: blob.sessionId,
                recipientDeviceId: ownDeviceId,
                senderDeviceId: blob.senderDeviceId,
              )
              .catchError((Object _) {}),
        );
        if (blob.senderUserId == senderUserId &&
            blob.senderDeviceId == payload.senderDeviceId &&
            inbound.sessionId == payload.sessionId) {
          importedTarget = true;
        }
      } on Object catch (_) {
        // Olm-decrypt failed / malformed blob — skip it, try the rest.
        continue;
      }
    }
    return importedTarget
        ? _GroupImportResult.imported
        : _GroupImportResult.noBlob;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Logout
  // ───────────────────────────────────────────────────────────────────────────

  /// Clear ALL local E2EE state for the current user on logout/account switch.
  ///
  /// IMPROVEMENT: web and RN clear only in-memory caches on logout, leaving the
  /// pickled account, sessions AND the decrypted-plaintext cache on disk — so a
  /// different user on the same install inherits the previous user's readable
  /// messages. We wipe the cache-db store and the durable secure-storage
  /// identity, closing that linkability gap.
  Future<void> onLogout() async {
    final userId = _accountUserId;
    _account = null;
    _accountUserId = null;
    _deviceId = null;
    _pickleKey = null;
    _status = E2eeRegistrationStatus.idle;
    _lastError = null;
    _bootstrapFuture = null;
    _bootstrapUserId = null;
    _lastBootstrapFailureAt = null;
    _sentByMessageId.clear();
    _sentByNonce.clear();
    try {
      await _store.wipeAll();
    } on Object catch (_) {}
    if (userId != null) {
      try {
        await _secure.clear(userId);
      } on Object catch (_) {}
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Helpers
  // ───────────────────────────────────────────────────────────────────────────

  Future<Map<String, E2eePrekeyBundle>> _claimFor(String userId) async {
    final list = await _api.claimPrekeyBundles(userId);
    return {for (final b in list) '$userId:${b.deviceId}': b};
  }

  Future<bool> _anyDeviceWithoutSession(
    String userId,
    List<E2eeDeviceInfo> devices,
  ) async {
    for (final d in devices) {
      // Our own current device is never a fan-out target, so ignore it here.
      if (userId == _accountUserId && d.deviceId == _deviceId) {
        continue;
      }
      final sessions = await _store.sessionsForDevice(userId, d.deviceId);
      if (sessions.isEmpty) {
        return true;
      }
    }
    return false;
  }

  /// Drop stored Olm sessions for any device whose published identity key has
  /// changed since we last saw it (so the next send rebuilds a fresh X3DH
  /// session instead of failing with a MAC error), and record the current key.
  Future<void> _applyRotationGuard(
    List<(String, E2eeDeviceInfo)> devices,
  ) async {
    for (final (userId, device) in devices) {
      final cached = await _store.peerIdentity(userId, device.deviceId);
      final newKey = device.identityKey;
      if (cached != null && cached.identityKey != newKey) {
        await _store.deleteSessionsForDevice(userId, device.deviceId);
      }
      if (cached?.identityKey != newKey) {
        await _store.writePeerIdentity(
          E2eePeerIdentitiesCompanion.insert(
            peerUserId: userId,
            peerDeviceId: device.deviceId,
            identityKey: newKey,
          ),
        );
      }
    }
  }

  Future<E2eeOlmSession> _loadOrCreateOutboundSession(
    _Target t,
    Uint8List pickleKey,
  ) async {
    final existing =
        await _store.sessionsForDevice(t.userId, t.device.deviceId);
    if (existing.isNotEmpty) {
      return E2eeOlmSession.fromPickle(existing.first.sessionPickle, pickleKey);
    }
    final otk = t.claim?.oneTimePrekey;
    if (otk == null) {
      throw StateError(
        'no one-time prekey for ${t.userId}:${t.device.deviceId}',
      );
    }
    return _account!.createOutboundSession(
      theirIdentityKey: t.device.identityKey,
      theirOneTimeKey: otk.publicKey,
    );
  }

  E2eeSignedPrekey _buildSelfSignedPrekey(E2eeAccount account) {
    // libolm has no dedicated signed-prekey primitive; self-sign the curve25519
    // identity key (id 0, public_key == identity_key) to fit the wire schema.
    final identityKey = account.identityKey;
    return E2eeSignedPrekey(
      keyId: 0,
      publicKey: identityKey,
      signature: account.sign(identityKey),
    );
  }

  List<E2eeOneTimePrekey> _generateOneTimePrekeys(E2eeAccount account) {
    account.generateOneTimeKeys(kOneTimeKeyBatchSize);
    final keys = account.oneTimeKeys; // local id -> base64 public key
    final out = <E2eeOneTimePrekey>[];
    var index = 0;
    for (final entry in keys.entries) {
      out.add(E2eeOneTimePrekey(
        keyId: hashKeyIdToInt(entry.key, index),
        publicKey: entry.value,
      ));
      index++;
    }
    // Mark published AFTER capturing them for the wire, so a later generate call
    // won't resurface these same keys.
    account.markKeysAsPublished();
    return out;
  }

  E2eeMessagePlaintextsCompanion _plaintextRow(
    String messageId,
    String? channelId,
    String text,
    String verification,
  ) =>
      E2eeMessagePlaintextsCompanion.insert(
        messageId: messageId,
        plaintext: text,
        channelId: Value(channelId),
        verificationStatus: Value(verification),
      );

  Uint8List _generatePickleKey() =>
      Uint8List.fromList(List<int>.generate(32, (_) => _random.nextInt(256)));

  String _generateDeviceId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _detectDeviceName() {
    if (Platform.isAndroid) {
      return 'Android';
    }
    if (Platform.isIOS) {
      return 'iOS';
    }
    if (Platform.isMacOS) {
      return 'macOS';
    }
    if (Platform.isWindows) {
      return 'Windows';
    }
    if (Platform.isLinux) {
      return 'Linux';
    }
    return 'Flutter';
  }
}
