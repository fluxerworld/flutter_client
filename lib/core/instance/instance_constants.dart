abstract final class InstanceConstants {
  static const int apiCodeVersion = 1;
  // Fluxerworld build: this instance's own endpoints. The API is served under
  // /api (no /v1 segment — that suffix is only for the upstream official hosts,
  // handled in InstanceConfigSnapshot._resolveApiBaseUrl). Runtime discovery
  // via /.well-known/fluxer overrides these once the app reaches the server.
  static const String defaultApiBaseUrl = 'https://fluxer.world/api';
  static const String defaultInstanceInputUrl = 'fluxer.world';
  static const int maxRecentInstances = 5;

  static const Set<String> officialInstanceHosts = <String>{
    'fluxer.world',
  };
}
