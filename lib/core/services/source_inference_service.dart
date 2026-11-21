
class SourceInferenceService {
  static const Map<int, String> _labelOfZone = {
    1: 'IT Department',
    2: 'CS Department',
    3: 'Engineering Department',
  };

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
