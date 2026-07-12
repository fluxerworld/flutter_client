import 'dart:async';

import 'package:fluxer_app/core/api/fluxer_client_provider.dart';
import 'package:fluxer_app/core/talker.dart';
import 'package:fluxer_app/features/mature_content/providers/sensitive_content_provider.dart';
import 'package:fluxer_app/features/ui/toast/fluxer_toast.dart';
import 'package:fluxer_app/features/ui/toast/toast_provider.dart';
import 'package:fluxer_dart/export.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'privacy_dashboard_view_model.g.dart';

// ---------------------------------------------------------------------------
// Flag constants
// ---------------------------------------------------------------------------

abstract final class FriendSourceFlag {
  static const int mutualFriends = 1 << 0;
  static const int mutualGuilds = 1 << 1;
  static const int noRelation = 1 << 2;
  static const int all = mutualFriends | mutualGuilds | noRelation;
}

abstract final class IncomingCallFlag {
  static const int friendsOfFriends = 1 << 0;
  static const int guildMembers = 1 << 1;
  static const int everyone = 1 << 2;
  static const int friendsOnly = 1 << 3;
  static const int nobody = 1 << 4;
  static const int silentEveryone = 1 << 5;
}

abstract final class GroupDmAddPermissionFlag {
  static const int friendsOfFriends = 1 << 0;
  static const int guildMembers = 1 << 1;
  static const int everyone = 1 << 2;
  static const int friendsOnly = 1 << 3;
  static const int nobody = 1 << 4;
}

abstract final class SensitiveMediaFilterValue {
  static const int show = 0;
  static const int blur = 1;
  static const int block = 2;
}

// ---------------------------------------------------------------------------
// Permission mode enum
// ---------------------------------------------------------------------------

enum PermissionMode { nobody, friendsOnly, custom, everyone }

// ---------------------------------------------------------------------------
// View state
// ---------------------------------------------------------------------------

const _sentinel = Object();

class PrivacyDashboardViewState {
  const PrivacyDashboardViewState({
    this.isLoading = true,
    this.error,
    // Connections
    this.friendSourceFlags = 0,
    this.defaultGuildsRestricted = false,
    this.botDefaultGuildsRestricted = false,
    // Communication
    this.incomingCallFlags = 0,
    this.groupDmAddPermissionFlags = 0,
    // Sensitive content — stored
    this.sensitiveContentFriendDmFilter = 0,
    this.sensitiveContentNonFriendDmFilter = 0,
    this.sensitiveContentGuildFilter = 0,
    this.blurUnscannedMedia = false,
    this.isAdult = false,
    // Sensitive content — edited
    this.editedFriendDmFilter,
    this.editedNonFriendDmFilter,
    this.editedGuildFilter,
    this.editedBlurUnscannedMedia,
    this.isSavingSensitiveContent = false,
    // Data export
    this.harvestStatus,
    // Data deletion
    this.pendingDeletion,
  });

  // Loading
  final bool isLoading;
  final String? error;

  // Connections
  final int friendSourceFlags;
  final bool defaultGuildsRestricted;
  final bool botDefaultGuildsRestricted;

  // Communication
  final int incomingCallFlags;
  final int groupDmAddPermissionFlags;

  // Sensitive content — stored server values
  final int sensitiveContentFriendDmFilter;
  final int sensitiveContentNonFriendDmFilter;
  final int sensitiveContentGuildFilter;
  final bool blurUnscannedMedia;
  final bool isAdult;

  // Sensitive content — local edits (null = not edited)
  final int? editedFriendDmFilter;
  final int? editedNonFriendDmFilter;
  final int? editedGuildFilter;
  final bool? editedBlurUnscannedMedia;
  final bool isSavingSensitiveContent;

  // Data export
  final HarvestStatusResponseSchema? harvestStatus;

  // Data deletion
  final UserPrivateResponsePendingBulkMessageDeletion? pendingDeletion;

  // ---------------------------------------------------------------------------
  // Computed — friend source flags
  // ---------------------------------------------------------------------------

  bool get everyoneCanFriendRequest =>
      friendSourceFlags & FriendSourceFlag.noRelation != 0;

  bool get friendsOfFriendsCanFriend =>
      friendSourceFlags & FriendSourceFlag.mutualFriends != 0;

  bool get communityMembersCanFriend =>
      friendSourceFlags & FriendSourceFlag.mutualGuilds != 0;

  // ---------------------------------------------------------------------------
  // Computed — incoming call flags
  // ---------------------------------------------------------------------------

  PermissionMode get incomingCallMode {
    if (incomingCallFlags & IncomingCallFlag.nobody != 0) {
      return PermissionMode.nobody;
    }
    if (incomingCallFlags & IncomingCallFlag.everyone != 0) {
      return PermissionMode.everyone;
    }
    final hasCustom =
        (incomingCallFlags & IncomingCallFlag.friendsOfFriends != 0) ||
        (incomingCallFlags & IncomingCallFlag.guildMembers != 0);
    if (hasCustom) {
      return PermissionMode.custom;
    }
    return PermissionMode.friendsOnly;
  }

  bool get callFriendsOfFriends =>
      incomingCallFlags & IncomingCallFlag.friendsOfFriends != 0;

  bool get callGuildMembers =>
      incomingCallFlags & IncomingCallFlag.guildMembers != 0;

  bool get silentCallsEnabled =>
      incomingCallFlags & IncomingCallFlag.silentEveryone != 0;

  // ---------------------------------------------------------------------------
  // Computed — group DM add permission flags
  // ---------------------------------------------------------------------------

  PermissionMode get groupDmAddMode {
    if (groupDmAddPermissionFlags & GroupDmAddPermissionFlag.nobody != 0) {
      return PermissionMode.nobody;
    }
    if (groupDmAddPermissionFlags & GroupDmAddPermissionFlag.everyone != 0) {
      return PermissionMode.everyone;
    }
    final hasCustom =
        (groupDmAddPermissionFlags &
                GroupDmAddPermissionFlag.friendsOfFriends !=
            0) ||
        (groupDmAddPermissionFlags & GroupDmAddPermissionFlag.guildMembers !=
            0);
    if (hasCustom) {
      return PermissionMode.custom;
    }
    return PermissionMode.friendsOnly;
  }

  bool get groupDmFriendsOfFriends =>
      groupDmAddPermissionFlags & GroupDmAddPermissionFlag.friendsOfFriends !=
      0;

  bool get groupDmGuildMembers =>
      groupDmAddPermissionFlags & GroupDmAddPermissionFlag.guildMembers != 0;

  // ---------------------------------------------------------------------------
  // Computed — sensitive content
  // ---------------------------------------------------------------------------

  int get effectiveFriendDmFilter =>
      editedFriendDmFilter ?? sensitiveContentFriendDmFilter;

  int get effectiveNonFriendDmFilter =>
      editedNonFriendDmFilter ?? sensitiveContentNonFriendDmFilter;

  int get effectiveGuildFilter =>
      editedGuildFilter ?? sensitiveContentGuildFilter;

  bool get effectiveBlurUnscannedMedia =>
      editedBlurUnscannedMedia ?? blurUnscannedMedia;

  bool get isSensitiveContentDirty =>
      (editedFriendDmFilter != null &&
          editedFriendDmFilter != sensitiveContentFriendDmFilter) ||
      (editedNonFriendDmFilter != null &&
          editedNonFriendDmFilter != sensitiveContentNonFriendDmFilter) ||
      (editedGuildFilter != null &&
          editedGuildFilter != sensitiveContentGuildFilter) ||
      (editedBlurUnscannedMedia != null &&
          editedBlurUnscannedMedia != blurUnscannedMedia);

  // ---------------------------------------------------------------------------
  // Computed — data deletion
  // ---------------------------------------------------------------------------

  bool get hasPendingDeletion => pendingDeletion != null;

  // ---------------------------------------------------------------------------
  // copyWith
  // ---------------------------------------------------------------------------

  PrivacyDashboardViewState copyWith({
    bool? isLoading,
    Object? error = _sentinel,
    int? friendSourceFlags,
    bool? defaultGuildsRestricted,
    bool? botDefaultGuildsRestricted,
    int? incomingCallFlags,
    int? groupDmAddPermissionFlags,
    int? sensitiveContentFriendDmFilter,
    int? sensitiveContentNonFriendDmFilter,
    int? sensitiveContentGuildFilter,
    bool? blurUnscannedMedia,
    bool? isAdult,
    Object? editedFriendDmFilter = _sentinel,
    Object? editedNonFriendDmFilter = _sentinel,
    Object? editedGuildFilter = _sentinel,
    Object? editedBlurUnscannedMedia = _sentinel,
    bool? isSavingSensitiveContent,
    Object? harvestStatus = _sentinel,
    Object? pendingDeletion = _sentinel,
  }) {
    return PrivacyDashboardViewState(
      isLoading: isLoading ?? this.isLoading,
      error: error == _sentinel ? this.error : error as String?,
      friendSourceFlags: friendSourceFlags ?? this.friendSourceFlags,
      defaultGuildsRestricted:
          defaultGuildsRestricted ?? this.defaultGuildsRestricted,
      botDefaultGuildsRestricted:
          botDefaultGuildsRestricted ?? this.botDefaultGuildsRestricted,
      incomingCallFlags: incomingCallFlags ?? this.incomingCallFlags,
      groupDmAddPermissionFlags:
          groupDmAddPermissionFlags ?? this.groupDmAddPermissionFlags,
      sensitiveContentFriendDmFilter:
          sensitiveContentFriendDmFilter ?? this.sensitiveContentFriendDmFilter,
      sensitiveContentNonFriendDmFilter:
          sensitiveContentNonFriendDmFilter ??
          this.sensitiveContentNonFriendDmFilter,
      sensitiveContentGuildFilter:
          sensitiveContentGuildFilter ?? this.sensitiveContentGuildFilter,
      blurUnscannedMedia: blurUnscannedMedia ?? this.blurUnscannedMedia,
      isAdult: isAdult ?? this.isAdult,
      editedFriendDmFilter: editedFriendDmFilter == _sentinel
          ? this.editedFriendDmFilter
          : editedFriendDmFilter as int?,
      editedNonFriendDmFilter: editedNonFriendDmFilter == _sentinel
          ? this.editedNonFriendDmFilter
          : editedNonFriendDmFilter as int?,
      editedGuildFilter: editedGuildFilter == _sentinel
          ? this.editedGuildFilter
          : editedGuildFilter as int?,
      editedBlurUnscannedMedia: editedBlurUnscannedMedia == _sentinel
          ? this.editedBlurUnscannedMedia
          : editedBlurUnscannedMedia as bool?,
      isSavingSensitiveContent:
          isSavingSensitiveContent ?? this.isSavingSensitiveContent,
      harvestStatus: harvestStatus == _sentinel
          ? this.harvestStatus
          : harvestStatus as HarvestStatusResponseSchema?,
      pendingDeletion: pendingDeletion == _sentinel
          ? this.pendingDeletion
          : pendingDeletion as UserPrivateResponsePendingBulkMessageDeletion?,
    );
  }
}

// ---------------------------------------------------------------------------
// View model
// ---------------------------------------------------------------------------

@Riverpod(keepAlive: true)
class PrivacyDashboardViewModel extends _$PrivacyDashboardViewModel {
  @override
  PrivacyDashboardViewState build() {
    unawaited(loadSettings());
    return const PrivacyDashboardViewState();
  }

  // ---------------------------------------------------------------------------
  // Load
  // ---------------------------------------------------------------------------

  Future<void> loadSettings() async {
    try {
      final client = ref.read(fluxerClientProvider);

      final settings = await client.users.getCurrentUserSettings();
      final user = await client.users.getCurrentUser();

      HarvestStatusResponseSchema? harvest;
      try {
        final harvestResponse = await client.users.getLatestDataHarvest();
        final json = harvestResponse.toJson();
        if (json.isNotEmpty) {
          harvest = HarvestStatusResponseSchema.fromJson(json);
        }
      } on Object {
        // No harvest exists — ignore.
      }

      state = state.copyWith(
        isLoading: false,
        error: null,
        friendSourceFlags: settings.friendSourceFlags,
        defaultGuildsRestricted: settings.defaultGuildsRestricted,
        botDefaultGuildsRestricted: settings.botDefaultGuildsRestricted,
        incomingCallFlags: settings.incomingCallFlags,
        groupDmAddPermissionFlags: settings.groupDmAddPermissionFlags,
        sensitiveContentFriendDmFilter:
            settings.sensitiveContentFriendDmFilter?.json ??
            SensitiveMediaFilterValue.show,
        sensitiveContentNonFriendDmFilter:
            settings.sensitiveContentNonFriendDmFilter?.json ??
            SensitiveMediaFilterValue.show,
        sensitiveContentGuildFilter:
            settings.sensitiveContentGuildFilter?.json ??
            SensitiveMediaFilterValue.show,
        isAdult: user.nsfwAllowed,
        pendingDeletion: user.pendingBulkMessageDeletion,
        harvestStatus: harvest,
      );
    } on Object catch (e, st) {
      talker.error('Failed to load privacy settings', e, st);
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Friend source flags
  // ---------------------------------------------------------------------------

  Future<void> updateFriendSourceFlag(int flag, {required bool enabled}) async {
    final previous = state.friendSourceFlags;
    int newFlags;

    if (flag == FriendSourceFlag.noRelation && enabled) {
      newFlags = FriendSourceFlag.all;
    } else if (enabled) {
      newFlags = previous | flag;
    } else {
      newFlags = previous & ~flag;
    }

    state = state.copyWith(friendSourceFlags: newFlags);

    try {
      final client = ref.read(fluxerClientProvider);
      await client.users.updateCurrentUserSettings(
        body: UserSettingsUpdateRequest(friendSourceFlags: newFlags),
      );
    } on Object catch (e, st) {
      talker.error('Failed to update friend source flags', e, st);
      state = state.copyWith(friendSourceFlags: previous);
    }
  }

  // ---------------------------------------------------------------------------
  // Default guilds restricted
  // ---------------------------------------------------------------------------

  Future<void> updateDefaultGuildsRestricted({
    required bool restricted,
    bool applyToAll = false,
  }) async {
    final previous = state.defaultGuildsRestricted;
    state = state.copyWith(defaultGuildsRestricted: restricted);

    try {
      final client = ref.read(fluxerClientProvider);
      await client.users.updateCurrentUserSettings(
        body: UserSettingsUpdateRequest(
          defaultGuildsRestricted: restricted,
          restrictedGuilds: applyToAll ? (restricted ? null : const []) : null,
        ),
      );
    } on Object catch (e, st) {
      talker.error('Failed to update default guilds restricted', e, st);
      state = state.copyWith(defaultGuildsRestricted: previous);
    }
  }

  // ---------------------------------------------------------------------------
  // Bot default guilds restricted
  // ---------------------------------------------------------------------------

  Future<void> updateBotDefaultGuildsRestricted({
    required bool restricted,
    bool applyToAll = false,
  }) async {
    final previous = state.botDefaultGuildsRestricted;
    state = state.copyWith(botDefaultGuildsRestricted: restricted);

    try {
      final client = ref.read(fluxerClientProvider);
      await client.users.updateCurrentUserSettings(
        body: UserSettingsUpdateRequest(
          botDefaultGuildsRestricted: restricted,
          botRestrictedGuilds: applyToAll
              ? (restricted ? null : const [])
              : null,
        ),
      );
    } on Object catch (e, st) {
      talker.error('Failed to update bot default guilds restricted', e, st);
      state = state.copyWith(botDefaultGuildsRestricted: previous);
    }
  }

  // ---------------------------------------------------------------------------
  // Incoming call flags
  // ---------------------------------------------------------------------------

  Future<void> updateIncomingCallFlags(int flags) async {
    final previous = state.incomingCallFlags;
    state = state.copyWith(incomingCallFlags: flags);

    try {
      final client = ref.read(fluxerClientProvider);
      await client.users.updateCurrentUserSettings(
        body: UserSettingsUpdateRequest(incomingCallFlags: flags),
      );
    } on Object catch (e, st) {
      talker.error('Failed to update incoming call flags', e, st);
      state = state.copyWith(incomingCallFlags: previous);
    }
  }

  // ---------------------------------------------------------------------------
  // Group DM add permission flags
  // ---------------------------------------------------------------------------

  Future<void> updateGroupDmAddPermissionFlags(int flags) async {
    final previous = state.groupDmAddPermissionFlags;
    state = state.copyWith(groupDmAddPermissionFlags: flags);

    try {
      final client = ref.read(fluxerClientProvider);
      await client.users.updateCurrentUserSettings(
        body: UserSettingsUpdateRequest(groupDmAddPermissionFlags: flags),
      );
    } on Object catch (e, st) {
      talker.error('Failed to update group DM add permission flags', e, st);
      state = state.copyWith(groupDmAddPermissionFlags: previous);
    }
  }

  // ---------------------------------------------------------------------------
  // Sensitive content — local edits
  // ---------------------------------------------------------------------------

  void editFriendDmFilter(int value) {
    state = state.copyWith(editedFriendDmFilter: value);
  }

  void editNonFriendDmFilter(int value) {
    state = state.copyWith(editedNonFriendDmFilter: value);
  }

  void editGuildFilter(int value) {
    state = state.copyWith(editedGuildFilter: value);
  }

  void editBlurUnscannedMedia({required bool value}) {
    state = state.copyWith(editedBlurUnscannedMedia: value);
  }

  void resetSensitiveContent() {
    state = state.copyWith(
      editedFriendDmFilter: null,
      editedNonFriendDmFilter: null,
      editedGuildFilter: null,
      editedBlurUnscannedMedia: null,
    );
  }

  // ---------------------------------------------------------------------------
  // Sensitive content — save via raw Dio
  // ---------------------------------------------------------------------------

  Future<void> saveSensitiveContent() async {
    if (!state.isSensitiveContentDirty) {
      return;
    }

    state = state.copyWith(isSavingSensitiveContent: true);

    try {
      final dio = ref.read(fluxerDioProvider);
      final body = <String, dynamic>{
        'sensitive_content_friend_dm_filter': state.effectiveFriendDmFilter,
        'sensitive_content_non_friend_dm_filter':
            state.effectiveNonFriendDmFilter,
        'sensitive_content_guild_filter': state.effectiveGuildFilter,
        'blur_unscanned_media': state.effectiveBlurUnscannedMedia,
      };

      await dio.patch<dynamic>('/users/@me/settings', data: body);

      state = state.copyWith(
        sensitiveContentFriendDmFilter: state.effectiveFriendDmFilter,
        sensitiveContentNonFriendDmFilter: state.effectiveNonFriendDmFilter,
        sensitiveContentGuildFilter: state.effectiveGuildFilter,
        blurUnscannedMedia: state.effectiveBlurUnscannedMedia,
        editedFriendDmFilter: null,
        editedNonFriendDmFilter: null,
        editedGuildFilter: null,
        editedBlurUnscannedMedia: null,
        isSavingSensitiveContent: false,
      );
      unawaited(ref.read(sensitiveContentProvider.notifier).load());
    } on Object catch (e, st) {
      talker.error('Failed to save sensitive content settings', e, st);
      state = state.copyWith(isSavingSensitiveContent: false);
      ref
          .read(toastProvider.notifier)
          .show(
            const FluxerToast(
              message: 'Failed to save sensitive content settings.',
              variant: FluxerToastVariant.danger,
            ),
          );
    }
  }

  // ---------------------------------------------------------------------------
  // Data export
  // ---------------------------------------------------------------------------

  Future<void> requestDataExport(Set<String> categories) async {
    try {
      final dio = ref.read(fluxerDioProvider);
      await dio.post<dynamic>(
        '/users/@me/harvest',
        data: <String, dynamic>{'categories': categories.toList()},
      );

      ref
          .read(toastProvider.notifier)
          .show(
            const FluxerToast(
              message: 'Data export requested successfully.',
              variant: FluxerToastVariant.success,
            ),
          );

      // Refresh harvest status
      try {
        final client = ref.read(fluxerClientProvider);
        final harvestResponse = await client.users.getLatestDataHarvest();
        final json = harvestResponse.toJson();
        if (json.isNotEmpty) {
          state = state.copyWith(
            harvestStatus: HarvestStatusResponseSchema.fromJson(json),
          );
        }
      } on Object {
        // Ignore refresh failures.
      }
    } on Object catch (e, st) {
      talker.error('Failed to request data export', e, st);
      ref
          .read(toastProvider.notifier)
          .show(
            const FluxerToast(
              message: 'Failed to request data export.',
              variant: FluxerToastVariant.danger,
            ),
          );
    }
  }

  // ---------------------------------------------------------------------------
  // Data deletion
  // ---------------------------------------------------------------------------

  Future<void> requestBulkMessageDeletion() async {
    try {
      final client = ref.read(fluxerClientProvider);
      await client.users.requestBulkMessageDeletion(
        body: const SudoVerificationSchema(),
      );

      ref
          .read(toastProvider.notifier)
          .show(
            const FluxerToast(
              message: 'Bulk message deletion requested.',
              variant: FluxerToastVariant.success,
            ),
          );

      // Refresh user to get pending deletion info
      final user = await client.users.getCurrentUser();
      state = state.copyWith(pendingDeletion: user.pendingBulkMessageDeletion);
    } on Object catch (e, st) {
      talker.error('Failed to request bulk message deletion', e, st);
      ref
          .read(toastProvider.notifier)
          .show(
            const FluxerToast(
              message: 'Failed to request message deletion.',
              variant: FluxerToastVariant.danger,
            ),
          );
    }
  }

  Future<void> cancelBulkMessageDeletion() async {
    try {
      final client = ref.read(fluxerClientProvider);
      await client.users.cancelBulkMessageDeletion();

      state = state.copyWith(pendingDeletion: null);

      ref
          .read(toastProvider.notifier)
          .show(
            const FluxerToast(
              message: 'Message deletion cancelled.',
              variant: FluxerToastVariant.success,
            ),
          );
    } on Object catch (e, st) {
      talker.error('Failed to cancel bulk message deletion', e, st);
      ref
          .read(toastProvider.notifier)
          .show(
            const FluxerToast(
              message: 'Failed to cancel message deletion.',
              variant: FluxerToastVariant.danger,
            ),
          );
    }
  }
}
