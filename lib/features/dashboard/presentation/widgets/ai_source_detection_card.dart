import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/config/zone_names.dart';


class AiSourceDetectionCard extends StatelessWidget {
  const AiSourceDetectionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final stream = Supabase.instance.client
        .from('noise_source_predictions')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .limit(1);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
      ),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          final row = (snapshot.data?.isNotEmpty ?? false) ? snapshot.data!.first : null;
          final bool noiseDetected = row?['noise_detected'] as bool? ?? false;

          final String? rawSource = row?['likely_source'] as String?;
          final String? likelySource =
              rawSource == null ? null : ZoneNames.forModelLabel(rawSource);
          final double confidence = ((row?['confidence'] as num?) ?? 0).toDouble();

          final Color statusColor =
              noiseDetected ? AppColors.statusCritical : AppColors.success;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.radar, size: 20, color: AppColors.textPrimary),
                  const SizedBox(width: 10),
                  Text(
                    'AI Source Detection',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Cross-references all 3 sensors to find the true origin',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 18),
              if (row == null)
                Text(
                  'Waiting for the first reading…',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                )
              else ...[
                _InfoRow(
                  label: 'Noise Detected',
                  value: noiseDetected ? 'YES' : 'NO',
                  valueColor: statusColor,
                ),
                const SizedBox(height: 10),
                _InfoRow(
                  label: 'Likely Source',
                  value: likelySource ?? '—',
                  valueColor: AppColors.textPrimary,
                ),
                const SizedBox(height: 10),
                _InfoRow(
                  label: 'Confidence',
                  value: '${(confidence * 100).toStringAsFixed(0)}%',
                  valueColor: AppColors.textPrimary,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, required this.valueColor});
  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        Text(
          value,
          style: TextStyle(color: valueColor, fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ],
    );
  }
}