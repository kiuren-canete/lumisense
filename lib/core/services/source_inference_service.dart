/// Finds WHERE a noise is coming from by comparing the 3 zone sensors.
///
/// Sound leaks through the room dividers, so every sensor hears something.
/// The sensor that hears it LOUDEST is the one closest to the source.
/// On the client's test recordings this simple rule named the right zone
/// about 87% of the time while a noise was happening (100% / 96% / 64% on
/// the three test stages). Trying to learn per-sensor quiet levels did not
/// help, so there is deliberately nothing to tune here.
///
/// Inputs, per zone id (1 = HIGHSCHOOL, 2 = STEM/HUMSS, 3 = GAS/TVL):
///   windowRms     average rms of that zone's last few readings
///                 (see MLInferenceService, key 'windowMeanRms')
///   soundLabels   that zone's sound type from MLInferenceService
///
/// Output: { noiseDetected, likelySource, confidence }
///   noiseDetected  false when the loudest zone itself sounds 'quiet'
///   likelySource   the model-era label of the loudest zone. The labels keep
///                  the ORIGINAL department names because the database and
///                  ZoneNames.forModelLabel() translate them for display
///                  (IT = zone 1, CS = zone 2, Engineering = zone 3).
///   confidence     loudest / (loudest + second loudest): 0.5 = a tie,
///                  close to 1.0 = clearly one zone.
class SourceInferenceService {
  static const Map<int, String> _labelOfZone = {
    1: 'IT Department',
    2: 'CS Department',
    3: 'Engineering Department',
  };

  /// Nothing to load any more — kept so callers can still `await initialize()`.
  Future<void> initialize() async {}

  Map<String, dynamic> classifySource({
    required Map<int, double> windowRms,
    required Map<int, String> soundLabels,
  }) {
    final zones =
        windowRms.keys.where((z) => _labelOfZone.containsKey(z)).toList();
    if (zones.length < 2) {
      return {'noiseDetected': false, 'likelySource': null, 'confidence': 0.0};
    }

    zones.sort((a, b) => windowRms[b]!.compareTo(windowRms[a]!));
    final loudest = zones[0];
    final topRms = windowRms[loudest]!;
    final secondRms = windowRms[zones[1]]!;

    final bool noiseDetected = (soundLabels[loudest] ?? 'unknown') != 'quiet';
    final double total = topRms + secondRms;
    final double confidence = total > 0 ? topRms / total : 0.0;

    return {
      'noiseDetected': noiseDetected,
      'likelySource': noiseDetected ? _labelOfZone[loudest] : null,
      'confidence': confidence,
    };
  }

  void dispose() {}
}
