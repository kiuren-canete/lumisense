import 'dart:async';
import 'dart:math' show log;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../domain/entities/zone_snapshot.dart';
import '../../config/zone_names.dart';
import '../../domain/repositories/telemetry_repository.dart';
import '../../domain/value_objects/noise_level.dart';
import '../ml_inference_service.dart';
import '../source_inference_service.dart';
import '../settings_service.dart';

// ─────────────────────────────────────────────────────────────
//  FIXED CONSTANTS (not user-configurable)
// ─────────────────────────────────────────────────────────────
const double _kTempMinC           = 19.0;   // °C — lower bound (fixed spec)
const Duration _kInactiveDuration = Duration(minutes: 10);

/// Connects to Supabase and listens for real-time sensor data.
/// Uses the full LUMISENSE SQL schema: sensor_readings, zone_status,
/// noise_events, audit_logs, buzzer_control.
class SupabaseTelemetryRepository implements TelemetryRepository {
  final SupabaseClient _client = Supabase.instance.client;
  final MLInferenceService _mlService = MLInferenceService();
  final SourceInferenceService _sourceMlService = SourceInferenceService();

  // Tracks which zones have already been logged as INACTIVE this cycle
  // so we don't spam the audit_logs on every stream event.
  final Set<int> _inactiveLogged = {};

  // The source prediction used to be written on EVERY stream update (thousands
  // of rows a day). Now: only when the answer changes, or every 30 seconds.
  static const Duration _sourceWriteEvery = Duration(seconds: 30);
  DateTime? _lastSourceWrite;
  String? _lastSourceKey;

  Future<void> initialize() async {
    await _mlService.initialize();
    await _sourceMlService.initialize();
  }

  @override
  Stream<List<ZoneSnapshot>> watchLiveZones() {
    try {
      return _client.from('sensor_readings').stream(primaryKey: ['id']).map((rows) {
        // Group by zone_id — keep the row with the highest id (latest reading).
        final Map<int, Map<String, dynamic>> latestPerZone = {};
        for (final row in rows) {
          final zoneId = row['zone_id'] as int;
          if (!latestPerZone.containsKey(zoneId) ||
              (row['id'] as int) > (latestPerZone[zoneId]!['id'] as int)) {
            latestPerZone[zoneId] = row;
          }
        }

        final List<ZoneSnapshot> snapshots = [];
        // Collected alongside snapshots so we can run the 3-sensor SOURCE
        // detection once per cycle (which zone hears the noise loudest).
        // Keys are zone ids: 1=HIGHSCHOOL (old IT), 2=STEM/HUMSS (old CS),
        // 3=GAS/TVL (old Engineering).
        final Map<int, double> zoneWindowRms = {};
        final Map<int, String> zoneSoundLabels = {};

        for (final row in latestPerZone.values) {
          final zoneId = row['zone_id'] as int;
          final double avg  = (row['avg']  as num?)?.toDouble() ?? 0;
          final double peak = (row['peak'] as num?)?.toDouble() ?? 0;
          final double min  = (row['min']  as num?)?.toDouble() ?? 0;
          final double rms  = (row['rms']  as num?)?.toDouble() ?? 0;
          final double temperatureC =
              (row['temperature_c'] as num?)?.toDouble() ?? 25.0;

          final DateTime updatedAt =
              DateTime.parse(row['created_at'] as String);

          // ── INACTIVE CHECK ─────────────────────────────────
          final bool isInactive =
              DateTime.now().difference(updatedAt) >= _kInactiveDuration;

          if (isInactive) {
            if (!_inactiveLogged.contains(zoneId)) {
              _inactiveLogged.add(zoneId);
              _logInactiveZone(zoneId: zoneId, lastSeen: updatedAt);
            }
            // Still show zone in UI but flagged as inactive
            snapshots.add(ZoneSnapshot(
              zoneId: zoneId.toString(),
              zoneName: _getZoneName(zoneId),
              temperatureC: temperatureC,
              noiseDb: 0,
              noiseLevel: NoiseLevel.quiet,
              soundClass: 'inactive',
              alertRaised: false,
              updatedAt: updatedAt,
              isInactive: true,
            ));
            continue;
          }

          // Zone came back online — clear the logged flag
          _inactiveLogged.remove(zoneId);

          // ── dB CONVERSION ───────────────────────────────────
          final double rawNoiseDb = rms > 0 ? 20 * _log10(rms / 1.0) : 0;

          // ── SETTINGS-DRIVEN THRESHOLDS ───────────────────────
          final s = SettingsService.instance.settings.value;
          final bool soundBreached  = rawNoiseDb > s.noiseWarningThreshold;
          final bool tempTooHot     = temperatureC > s.tempThreshold;
          final bool tempTooCold    = temperatureC < _kTempMinC;
          final bool tempBreached   = tempTooHot || tempTooCold;

          // ANN classification
          final result = _mlService.classifySound(
            zoneId: zoneId,
            readingId: row['id'] as int,
            time: updatedAt,
            avg: avg,
            peak: peak,
            min: min,
            rms: rms,
          );
          final String soundClass = result['label'] as String;

          // Remember this zone's window loudness + sound type for the
          // SOURCE detection below (needs all 3 zones at once).
          zoneWindowRms[zoneId] = (result['windowMeanRms'] as num).toDouble();
          zoneSoundLabels[zoneId] = soundClass;
          final List<Map<String, dynamic>> soundProfile =
              (result['profile'] as List?)
                  ?.map((e) => (e as Map).cast<String, dynamic>())
                  .toList() ??
              const <Map<String, dynamic>>[];

          // Compute noise level — if either threshold is breached, escalate
          NoiseLevel level = _resolveNoiseLevel(rawNoiseDb);
          if (soundBreached || tempBreached) {
            // Ensure at minimum "warning" when a threshold is exceeded
            if (level.index < NoiseLevel.warning.index) {
              level = NoiseLevel.warning;
            }
          }

          final bool alertRaised =
              level == NoiseLevel.warning || level == NoiseLevel.critical;

          // Push AI analysis + threshold decisions back to Supabase
          _updateBackendStatus(
            zoneId: zoneId,
            noiseLabel: soundClass,
            noiseLevel: level,
            rms: rms,
            rawNoiseDb: rawNoiseDb,
            temperatureC: temperatureC,
            alertRaised: alertRaised,
            soundBreached: soundBreached,
            tempBreached: tempBreached,
            tempTooHot: tempTooHot,
          );

          snapshots.add(ZoneSnapshot(
            zoneId: zoneId.toString(),
            zoneName: _getZoneName(zoneId),
            temperatureC: temperatureC,
            noiseDb: rawNoiseDb,
            noiseLevel: level,
            soundClass: soundClass,
            soundProfile: soundProfile,
            alertRaised: alertRaised,
            updatedAt: updatedAt,
            isInactive: false,
          ));
        }

        // ── FUSED SOURCE CLASSIFICATION ────────────────────────
        // Only meaningful once we have a fresh, simultaneous reading
        // from all 3 zones this cycle — a partial set (e.g. one zone
        // inactive) can't be compared fairly against the others.
        if (zoneWindowRms.length == 3) {
          final sourceResult = _sourceMlService.classifySource(
            windowRms: zoneWindowRms,
            soundLabels: zoneSoundLabels,
          );

          final sourceKey =
              '${sourceResult['noiseDetected']}|${sourceResult['likelySource']}';
          final now = DateTime.now();
          if (sourceKey != _lastSourceKey ||
              _lastSourceWrite == null ||
              now.difference(_lastSourceWrite!) >= _sourceWriteEvery) {
            _lastSourceKey = sourceKey;
            _lastSourceWrite = now;
            // Column names (cs_rms / eng_rms / it_rms) are kept from the
            // old schema: cs = zone 2, eng = zone 3, it = zone 1.
            _recordSourcePrediction(
              sourceResult: sourceResult,
              csRms: zoneWindowRms[2]!,
              engRms: zoneWindowRms[3]!,
              itRms: zoneWindowRms[1]!,
            );
          }
        }

        return snapshots;
      });
    } catch (e) {
      return const Stream.empty();
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Mute or un-mute the buzzer for a zone.
  //  mute=true  → mode='manual', manual_state=false (silenced)
  //  mute=false → mode='auto'   (restored to AI control)
  // ─────────────────────────────────────────────────────────
  Future<void> setMuteZone({
    required int zoneId,
    required bool mute,
  }) async {
    try {
      await _client.from('buzzer_control').upsert({
        'zone_id': zoneId,
        'mode': mute ? 'manual' : 'auto',
        'manual_state': false,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────
  //  Trigger the buzzer override for a specific zone.
  //  Sets mode='manual' + manual_state=true then resets after
  //  [durationSeconds] seconds.
  // ─────────────────────────────────────────────────────────
  Future<void> triggerBuzzerOverride({
    required int zoneId,
    int durationSeconds = 5,
  }) async {
    try {
      await _client.from('buzzer_control').upsert({
        'zone_id': zoneId,
        'mode': 'manual',
        'manual_state': true,
        'updated_at': DateTime.now().toIso8601String(),
      });

      // Auto-reset after the given duration
      Future.delayed(Duration(seconds: durationSeconds), () async {
        try {
          await _client.from('buzzer_control').upsert({
            'zone_id': zoneId,
            'mode': 'auto',
            'manual_state': false,
            'updated_at': DateTime.now().toIso8601String(),
          });
        } catch (_) {}
      });
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────
  //  Write to Supabase after every AI classification cycle
  // ─────────────────────────────────────────────────────────
  Future<void> _updateBackendStatus({
    required int zoneId,
    required String noiseLabel,
    required NoiseLevel noiseLevel,
    required double rms,
    required double rawNoiseDb,
    required double temperatureC,
    required bool alertRaised,
    required bool soundBreached,
    required bool tempBreached,
    required bool tempTooHot,
  }) async {
    try {
      final levelStr = noiseLevel.toString().split('.').last;

      String ledColor = 'green';
      if (levelStr == 'critical') {
        ledColor = 'red';
      } else if (levelStr == 'warning') {
        ledColor = 'blue';
      }

      await _client.from('zone_status').upsert({
        'zone_id': zoneId,
        'noise_label': noiseLabel,
        'noise_level': levelStr,
        'led_color': ledColor,
        'buzzer_active': alertRaised,
        'updated_at': DateTime.now().toIso8601String(),
      });

      // Log noise event for warning / critical
      if (alertRaised) {
        final String eventDesc = _buildEventDescription(
          noiseLabel: noiseLabel,
          noiseDb: rawNoiseDb,
          temperatureC: temperatureC,
          soundBreached: soundBreached,
          tempBreached: tempBreached,
          tempTooHot: tempTooHot,
        );

        await _client.from('noise_events').insert({
          'zone_id': zoneId,
          'noise_label': noiseLabel,
          'noise_level': levelStr,
          'rms': rms,
          'temperature_c': temperatureC,
          'event_description': eventDesc,
          'severity': levelStr == 'critical' ? 'critical' : 'warning',
        });

        // Also write to audit_logs so the Statistics page picks it up
        await _client.from('audit_logs').insert({
          'zone_id': zoneId,
          'department': _getDepartmentShort(zoneId),
          'event': eventDesc,
          'severity': levelStr == 'critical' ? 'critical' : 'warning',
        });
      }

      // Threshold-specific audit log entries (sound / temp)
      if (soundBreached) {
        final s = SettingsService.instance.settings.value;
        await _logThresholdBreach(
          zoneId: zoneId,
          event:
              'Sound threshold exceeded: ${rawNoiseDb.toStringAsFixed(1)} dB '
              '(max ${s.noiseWarningThreshold.toStringAsFixed(0)} dB)',
          severity: 'warning',
        );
      }
      if (tempBreached) {
        final s = SettingsService.instance.settings.value;
        final rangeHint = tempTooHot
            ? 'above max ${s.tempThreshold.toStringAsFixed(0)}°C'
            : 'below min ${_kTempMinC.toStringAsFixed(0)}°C';
        await _logThresholdBreach(
          zoneId: zoneId,
          event:
              'Temperature out of range: ${temperatureC.toStringAsFixed(1)}°C '
              '($rangeHint)',
          severity: 'warning',
        );
      }
    } catch (_) {
      // Fail silently if disconnected
    }
  }

  // ─────────────────────────────────────────────────────────
  //  Log an INACTIVE zone to audit_logs
  // ─────────────────────────────────────────────────────────
  Future<void> _logInactiveZone({
    required int zoneId,
    required DateTime lastSeen,
  }) async {
    try {
      final minutesAgo =
          DateTime.now().difference(lastSeen).inMinutes;
      await _client.from('audit_logs').insert({
        'zone_id': zoneId,
        'department': _getDepartmentShort(zoneId),
        'event':
            'Zone marked INACTIVE — no data received for $minutesAgo minutes '
            '(last seen: ${lastSeen.toLocal()})',
        'severity': 'warning',
      });
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────
  //  Deduplicate threshold breach logs (avoid spamming on
  //  every 1-second reading). Tracks last-logged time per
  //  zone+type in memory.
  // ─────────────────────────────────────────────────────────
  final Map<String, DateTime> _lastThresholdLog = {};
  static const Duration _thresholdLogCooldown = Duration(minutes: 2);

  Future<void> _logThresholdBreach({
    required int zoneId,
    required String event,
    required String severity,
  }) async {
    final key = '$zoneId:$event';
    final now = DateTime.now();
    final last = _lastThresholdLog[key];
    if (last != null && now.difference(last) < _thresholdLogCooldown) return;
    _lastThresholdLog[key] = now;

    try {
      await _client.from('audit_logs').insert({
        'zone_id': zoneId,
        'department': _getDepartmentShort(zoneId),
        'event': event,
        'severity': severity,
      });
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────────────────
  NoiseLevel _resolveNoiseLevel(double db) {
    final s = SettingsService.instance.settings.value;
    if (db >= s.noiseCriticalThreshold) return NoiseLevel.critical;
    if (db >= s.noiseWarningThreshold)  return NoiseLevel.warning;
    if (db >= 45) return NoiseLevel.normal;
    return NoiseLevel.quiet;
  }

  String _getZoneName(int zoneId) => ZoneNames.forZoneId(zoneId);

  String _getDepartmentShort(int zoneId) => ZoneNames.forZoneId(zoneId);

  /// Persists the fused SOURCE model's latest prediction. Best-effort —
  /// a failure here should never interrupt the live-zones stream.
  Future<void> _recordSourcePrediction({
    required Map<String, dynamic> sourceResult,
    required double csRms,
    required double engRms,
    required double itRms,
  }) async {
    try {
      await _client.from('noise_source_predictions').insert({
        'noise_detected': sourceResult['noiseDetected'],
        'likely_source': sourceResult['likelySource'],
        'confidence': sourceResult['confidence'],
        'cs_rms': csRms,
        'eng_rms': engRms,
        'it_rms': itRms,
      });
    } catch (e) {
      // Non-fatal — table may not be migrated yet, or we're offline.
    }
  }

  String _buildEventDescription({
    required String noiseLabel,
    required double noiseDb,
    required double temperatureC,
    required bool soundBreached,
    required bool tempBreached,
    required bool tempTooHot,
  }) {
    final s = SettingsService.instance.settings.value;
    final parts = <String>[];
    if (soundBreached) {
      parts.add('Sound ${noiseDb.toStringAsFixed(1)} dB exceeds '
          '${s.noiseWarningThreshold.toStringAsFixed(0)} dB limit');
    }
    if (tempBreached) {
      parts.add('Temp ${temperatureC.toStringAsFixed(1)}°C is '
          '${tempTooHot ? "above max ${s.tempThreshold.toStringAsFixed(0)}°C" : "below min ${_kTempMinC.toStringAsFixed(0)}°C"}');
    }
    if (parts.isEmpty) {
      parts.add('$noiseLabel detected at ${noiseDb.toStringAsFixed(1)} dB');
    }
    return parts.join(' · ');
  }

  double _log10(double x) => x > 0 ? log(x) / log(10) : 0;
}