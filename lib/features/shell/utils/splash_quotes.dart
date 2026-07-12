import 'dart:math';

class SplashQuote {
  const SplashQuote({required this.text, required this.source});
  final String text;
  final String source;
}

// Fluxerworld ships no loading sayings under the boot logo. The upstream
// fluxer.app quotes were attributed to their community members (kitkatz, vky,
// jackzie, ...), not ours, so they must not appear in this build. The splash
// screen no longer renders quotes; this stays a valid (empty) source.
const List<SplashQuote> _baseSplashQuotes = <SplashQuote>[];

List<SplashQuote> buildSplashQuotes() =>
    List<SplashQuote>.from(_baseSplashQuotes);

SplashQuote pickRandomSplashQuote() {
  final List<SplashQuote> quotes = buildSplashQuotes();
  if (quotes.isEmpty) {
    return const SplashQuote(text: '', source: '');
  }
  return quotes[Random().nextInt(quotes.length)];
}
