import 'dart:math';

import '../../domain/entities/zone_snapshot.dart';
import '../../config/zone_names.dart';
import '../../domain/repositories/telemetry_repository.dart';
import '../../domain/value_objects/noise_level.dart';

class MockTelemetryRepository implements TelemetryRepository {
  final Random _random = Random();

  @override
  Stream<List<ZoneSnapshot>> watchLiveZones() async* {
    yield _buildSnapshots();

    while (true) {
      await Future<void>.delayed(const Duration(seconds: 2));
      yield _buildSnapshots();
    }
  }

  List<ZoneSnapshot> _buildSnapshots() {
    final now = DateTime.now();
    final zones = [
      (id: 'it', name: ZoneNames.zone1),
      (id: 'cs', name: ZoneNames.zone2),
      (id: 'eng', name: ZoneNames.zone3),
    ];

    return zones.map((zone) {
      final temp = 21 + _random.nextDouble() * 8;
      final noise = 35 + _random.nextDouble() * 45;
      final level = _resolveNoiseLevel(noise);
      final profile = _buildSoundProfile(zone.id, level);
      final soundClass = profile.isNotEmpty
          ? (profile.first['label'] as String)
          : _soundClassFor(level);
      return ZoneSnapshot(
        zoneId: zone.id,
        zoneName: zone.name,
        temperatureC: temp,
        noiseDb: noise,
        noiseLevel: level,
        soundClass: soundClass,
        soundProfile: profile,
        alertRaised:
            level == NoiseLevel.warning || level == NoiseLevel.critical,
        updatedAt: now,
      );
    }).toList();
  }


  List<Map<String, dynamic>> _buildSoundProfile(String zoneId, NoiseLevel level) {

    final Map<String, List<(String, double)>> templates = {
      'it': [
        ('keyboard_typing',  0.45),
        ('conversation',     0.28),
        ('fan_noise',        0.15),
        ('ambient',          0.08),
        ('phone_ringing',    0.04),
      ],
      'cs': [
        ('conversation',     0.42),
        ('phone_ringing',    0.25),
        ('ambient',          0.18),
        ('keyboard_typing',  0.10),
        ('door_closing',     0.05),
      ],
      'eng': [
        ('machinery',        0.38),
        ('loud_talking',     0.26),
        ('tools',            0.20),
        ('footsteps',        0.10),
        ('ambient',          0.06),
      ],
    };

    final base = templates[zoneId] ?? templates['it']!;

    // Add random jitter (±8%) so the graph fluctuates naturally
    final rawItems = base.map((entry) {
      final jitter = (_random.nextDouble() - 0.5) * 0.16;
      final conf = (entry.$2 + jitter).clamp(0.01, 1.0);
      return {'label': entry.$1, 'confidence': conf};
    }).toList();

    // Re-normalise so total = 1.0
    final total = rawItems.fold<double>(
        0.0, (sum, e) => sum + (e['confidence'] as double));
    for (final item in rawItems) {
      item['confidence'] = (item['confidence'] as double) / total;
    }

    // Sort highest first (matches what the real ML service returns)
    rawItems.sort((a, b) =>
        (b['confidence'] as double).compareTo(a['confidence'] as double));

    return rawItems;
  }

  NoiseLevel _resolveNoiseLevel(double db) {
    if (db >= 72) return NoiseLevel.critical;
    if (db >= 60) return NoiseLevel.warning;
    if (db >= 45) return NoiseLevel.normal;
    return NoiseLevel.quiet;
  }

  String _soundClassFor(NoiseLevel level) {
    switch (level) {
      case NoiseLevel.quiet:
        return 'ambient';
      case NoiseLevel.normal:
        return 'conversation';
      case NoiseLevel.warning:
        return 'chair_dragging';
      case NoiseLevel.critical:
        return 'loud_talking';
    }
  }
}