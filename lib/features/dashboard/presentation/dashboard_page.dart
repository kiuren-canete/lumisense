import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/config/zone_names.dart';
import 'widgets/department_card.dart';
import 'widgets/floor_plan_widget.dart';
import 'widgets/action_center.dart';
import 'widgets/summary_panel.dart';
import 'widgets/ai_source_detection_card.dart';
import '../../../core/domain/entities/zone_snapshot.dart';
import '../../../core/domain/value_objects/noise_level.dart';

import '../../../core/services/supabase/supabase_telemetry_repository.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _repository = SupabaseTelemetryRepository();
  late final Stream<List<ZoneSnapshot>> _liveZonesStream;

  @override
  void initState() {
    super.initState();
    _repository.initialize();
    _liveZonesStream = _repository.watchLiveZones();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();

    return ColoredBox(
      color: AppColors.workspaceBg,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 64,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Dashboard',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: AppColors.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formattedDate(now),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.textSecondary,
                              fontSize: 13,
                            ),
                      ),
                    ],
                  ),
                  const Spacer(),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: StreamBuilder<List<ZoneSnapshot>>(
                stream: _liveZonesStream,
                builder: (context, snapshot) {
                  final liveZones = snapshot.data;
                  final displayZones = _mergeWithDefaults(liveZones ?? []);

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 7,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 3,
                              child: FloorPlanWidget(liveZones: liveZones),
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              flex: 2,
                              child: _LiveZonesPanel(zones: displayZones),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ActionCenter(),
                            SizedBox(height: 16),
                            AiSourceDetectionCard(),
                            SizedBox(height: 16),
                            Expanded(child: SummaryPanel()),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Ensures all 3 department zones are always visible.
  /// Live data overrides defaults; missing zones get placeholders.
  List<ZoneSnapshot> _mergeWithDefaults(List<ZoneSnapshot> live) {
    // Default mock sound profiles per department
    const defaultProfiles = <String, List<Map<String, dynamic>>>{
      '1': [
        {'label': 'keyboard_typing', 'confidence': 0.45},
        {'label': 'conversation', 'confidence': 0.28},
        {'label': 'fan_noise', 'confidence': 0.15},
      ],
      '2': [
        {'label': 'conversation', 'confidence': 0.42},
        {'label': 'phone_ringing', 'confidence': 0.25},
        {'label': 'ambient', 'confidence': 0.18},
      ],
      '3': [
        {'label': 'machinery', 'confidence': 0.38},
        {'label': 'loud_talking', 'confidence': 0.26},
        {'label': 'tools', 'confidence': 0.20},
      ],
    };

    const defaultZones = [
      ('1', ZoneNames.zone1),
      ('2', ZoneNames.zone2),
      ('3', ZoneNames.zone3),
    ];

    final Map<String, ZoneSnapshot> merged = {};

    // Start with defaults
    for (final (id, name) in defaultZones) {
      merged[id] = ZoneSnapshot(
        zoneId: id,
        zoneName: name,
        temperatureC: 25.0,
        noiseDb: 0,
        noiseLevel: NoiseLevel.quiet,
        soundClass: defaultProfiles[id]?.first['label'] as String? ?? 'waiting',
        soundProfile: defaultProfiles[id] ?? const [],
        alertRaised: false,
        updatedAt: DateTime.now(),
      );
    }

    // Override with live data
    for (final z in live) {
      merged[z.zoneId] = z;
    }

    return merged.values.toList();
  }

  String _formattedDate(DateTime dt) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    const days = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    return '${days[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}

class _LiveZonesPanel extends StatelessWidget {
  const _LiveZonesPanel({required this.zones});

  final List<ZoneSnapshot> zones;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: AppColors.shadowMedium,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Live Zones',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 14),
          Expanded(child: _buildZones(context)),
        ],
      ),
    );
  }

  Widget _buildZones(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < zones.length; i++) {
      if (i > 0) {
        children.add(
          VerticalDivider(
            color: AppColors.surfaceHighlight.withValues(alpha: 0.8),
            width: 32,
            thickness: 1,
          ),
        );
      }
      children.add(
        Expanded(
          child: SingleChildScrollView(
            child: DepartmentCard(snapshot: zones[i]),
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}