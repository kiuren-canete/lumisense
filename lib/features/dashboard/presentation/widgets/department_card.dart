import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../core/domain/entities/zone_snapshot.dart';
import '../../../../core/domain/value_objects/noise_level.dart';
import '../../../../core/services/settings_service.dart';
import '../../../../core/theme/app_colors.dart';
import 'sound_confidence_graph.dart';

const double _kTempMinC = 19.0;

class DepartmentCard extends StatelessWidget {
  const DepartmentCard({super.key, required this.snapshot});

  final ZoneSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
  
    if (snapshot.isInactive) {
      return _InactiveZoneCard(snapshot: snapshot);
    }

    final status = _statusInfo(snapshot.noiseLevel);


    final s = SettingsService.instance.settings.value;
    final bool soundBreached = snapshot.noiseDb > s.noiseWarningThreshold;
    final bool tempHot       = snapshot.temperatureC > s.tempThreshold;
    final bool tempCold      = snapshot.temperatureC < _kTempMinC;
    final bool tempBreached  = tempHot || tempCold;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
  
        Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _iconForZone(snapshot.zoneId),
                color: AppColors.textPrimary,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    snapshot.zoneName,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _timeSince(snapshot.updatedAt),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.textTertiary,
                          fontSize: 12,
                        ),
                  ),
                ],
              ),
            ),
            _StatusBadge(label: status.label, color: status.color),
          ],
        ),

        const SizedBox(height: 16),
        const Divider(color: AppColors.separator, thickness: 0.5, height: 1),
        const SizedBox(height: 8),

        _MetricRow(
          icon: LucideIcons.volume2,
          label: 'Sound Level',
          value: '${snapshot.noiseDb.toStringAsFixed(1)} dB',
          color: soundBreached ? AppColors.warning : AppColors.textPrimary,
          breached: soundBreached,
          breachHint: 'Exceeds ${s.noiseWarningThreshold.toStringAsFixed(0)} dB limit',
        ),
        _MetricRow(
          icon: LucideIcons.thermometer,
          label: 'Temperature',
          value: '${snapshot.temperatureC.toStringAsFixed(1)}°C',
          color: tempBreached ? AppColors.warning : AppColors.textPrimary,
          breached: tempBreached,
          breachHint: tempHot
              ? 'Above ${s.tempThreshold.toStringAsFixed(0)}°C max'
              : tempCold
                  ? 'Below ${_kTempMinC.toStringAsFixed(0)}°C min'
                  : '',
        ),

        if (soundBreached || tempBreached) ...[
          const SizedBox(height: 4),
          _ThresholdBanner(soundBreached: soundBreached, tempBreached: tempBreached),
        ],

        const SizedBox(height: 8),
        const Divider(color: AppColors.separator, thickness: 0.5, height: 1),

        _SoundTypeSection(soundProfile: snapshot.soundProfile),
      ],
    );
  }

  IconData _iconForZone(String zoneId) {
    switch (zoneId) {
      case '1': return LucideIcons.monitorSpeaker;
      case '2': return LucideIcons.server;
      case '3': return LucideIcons.cpu;
      default:  return LucideIcons.building;
    }
  }

  String _timeSince(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 10) return 'Just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }

  _StatusData _statusInfo(NoiseLevel level) {
    switch (level) {
      case NoiseLevel.quiet:    return _StatusData('Live',     AppColors.statusLive);
      case NoiseLevel.normal:   return _StatusData('Stable',   AppColors.statusStable);
      case NoiseLevel.warning:  return _StatusData('Caution',  AppColors.statusWarning);
      case NoiseLevel.critical: return _StatusData('Critical', AppColors.statusCritical);
    }
  }
}


class _InactiveZoneCard extends StatelessWidget {
  const _InactiveZoneCard({required this.snapshot});
  final ZoneSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final minutesAgo = DateTime.now().difference(snapshot.updatedAt).inMinutes;

    return Opacity(
      opacity: 0.55,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(LucideIcons.wifiOff, color: AppColors.textTertiary, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snapshot.zoneName,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Last seen $minutesAgo min ago',
                      style: const TextStyle(
                        color: AppColors.statusWarning,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const _StatusBadge(label: 'Inactive', color: AppColors.statusWarning),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.statusWarning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.statusWarning.withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                const Icon(LucideIcons.alertTriangle, size: 14, color: AppColors.statusWarning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No data received for more than 10 minutes. '
                    'Check device connection.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.statusWarning,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class _ThresholdBanner extends StatelessWidget {
  const _ThresholdBanner({
    required this.soundBreached,
    required this.tempBreached,
  });

  final bool soundBreached;
  final bool tempBreached;

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance.settings.value;
    final parts = <String>[];
    if (soundBreached) parts.add('Sound >${s.noiseWarningThreshold.toStringAsFixed(0)} dB');
    if (tempBreached) {
      parts.add('Temp outside ${_kTempMinC.toStringAsFixed(0)}–${s.tempThreshold.toStringAsFixed(0)}°C');
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.alertTriangle, size: 13, color: AppColors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Threshold breached: ${parts.join(" · ")}',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.warning,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusData {
  final String label;
  final Color color;
  _StatusData(this.label, this.color);
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool breached;
  final String breachHint;

  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.breached = false,
    this.breachHint = '',
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: breached ? AppColors.warning : AppColors.textTertiary),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          if (breached) ...[
            const Icon(LucideIcons.alertTriangle, size: 12, color: AppColors.warning),
            const SizedBox(width: 4),
          ],
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _SoundTypeSection extends StatelessWidget {
  const _SoundTypeSection({required this.soundProfile});
  final List<Map<String, dynamic>> soundProfile;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(LucideIcons.waves, size: 16, color: AppColors.textTertiary),
            const SizedBox(width: 10),
            const Text(
              'Live Sound Profile',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SoundConfidenceGraph(soundProfile: soundProfile),
      ],
    );
  }
}