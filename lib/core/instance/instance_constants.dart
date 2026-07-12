abstract final class InstanceConstants {
  static const int apiCodeVersion = 1;
  // Fluxerworld build: this instance's own endpoints. The API is served under
  // /api (no /v1 segment — that suffix is only for the upstream official hosts,
  // handled in InstanceConfigSnapshot._resolveApiBaseUrl). Runtime discovery
  // via /.well-known/fluxer overrides these once the app reaches the server.
  static const String defaultApiBaseUrl = 'https://fluxer.world/api';
  // The gateway is path-based (wss://<host>/gateway), not a `gateway.` subdomain
  // like the upstream official hosts. Without this, officialDefault() left the
  // gateway URL empty and the SDK fell back to deriving wss://fluxer.world (no
  // /gateway path), which hits the webroot and never upgrades -> boot reaches
  // the app then dies on "Reconnect failure timeout reached".
  static const String defaultGateway = 'wss://fluxer.world/gateway';
  static const String defaultInstanceInputUrl = 'fluxer.world';
  static const int maxRecentInstances = 5;

  static const Set<String> officialInstanceHosts = <String>{
    'fluxer.world',
  };
}
