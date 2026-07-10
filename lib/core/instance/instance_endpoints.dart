import 'package:fluxer_dart/export.dart';

/// Instance URLs from `/.well-known/fluxer`, with compile-time fallbacks until loaded.
// Preserves the global endpoint holder API used across provider and link code.
// ignore: avoid_classes_with_only_static_members
abstract final class InstanceEndpoints {
  // Fluxerworld build: pre-discovery fallbacks pointing at our own instance.
  // /.well-known/fluxer overrides all of these at runtime (InstanceEndpoints.apply).
  // These must never point at fluxerstatic.com or web.fluxer.app — neither is ours.
  static const String defaultMedia = 'https://fluxer.world/media';
  static const String defaultStaticCdn = 'https://fluxer.world';
  static const String defaultInvite = 'https://fluxer.world/invite';
  static const String defaultWebApp = 'https://fluxer.world';

  static String staticCdn = defaultStaticCdn;
  static String media = defaultMedia;
  static String invite = defaultInvite;
  static String webApp = defaultWebApp;
  static String api = '';
  static String gateway = '';

  static void apply(WellKnownFluxerResponse response) {
    final WellKnownFluxerResponseEndpoints endpoints = response.endpoints;
    staticCdn = _normalizeBaseUrl(
      endpoints.staticCdn,
      fallback: defaultStaticCdn,
    );
    media = _normalizeBaseUrl(endpoints.media, fallback: defaultMedia);
    invite = _normalizeBaseUrl(endpoints.invite, fallback: defaultInvite);
    webApp = _normalizeBaseUrl(endpoints.webapp, fallback: defaultWebApp);
    final String resolvedApi = endpoints.apiClient.isNotEmpty
        ? endpoints.apiClient
        : endpoints.api;
    api = resolvedApi.isNotEmpty ? _normalizeBaseUrl(resolvedApi) : api;
    gateway = endpoints.gateway.isNotEmpty ? endpoints.gateway : gateway;
  }

  static String _normalizeBaseUrl(String value, {String? fallback}) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return fallback ?? trimmed;
    }
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }

  static void resetToDefaults() {
    staticCdn = defaultStaticCdn;
    media = defaultMedia;
    invite = defaultInvite;
    webApp = defaultWebApp;
    api = '';
    gateway = '';
  }
}
