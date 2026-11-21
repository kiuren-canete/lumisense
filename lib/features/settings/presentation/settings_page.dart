import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../../core/models/app_settings.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/theme/app_colors.dart';
import 'widgets/ai_model_management_section.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late AppSettings _draft;

  bool _hasUnsavedChanges = false;
  bool _isSaving = false;

  final _patternNames = ['Continuous', 'Pulsing', 'Escalating', 'Short Burst'];
  final _patternValues = ['continuous', 'pulsing', 'escalating', 'short_burst'];

  @override
  void initState() {
    super.initState();

    _draft = SettingsService.instance.settings.value;

    SettingsService.instance.settings.addListener(_onSettingsUpdated);
  }

  @override
  void dispose() {
    SettingsService.instance.settings.removeListener(_onSettingsUpdated);
    super.dispose();
  }

  void _onSettingsUpdated() {
    if (!_hasUnsavedChanges) {
      setState(() => _draft = SettingsService.instance.settings.value);
    }
  }

  void _markDirty() {
    if (!_hasUnsavedChanges) setState(() => _hasUnsavedChanges = true);
  }

  Future<void> _saveAll() async {
    setState(() => _isSaving = true);
    final ok = await SettingsService.instance.save(_draft);
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      if (ok) _hasUnsavedChanges = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              ok ? LucideIcons.check : LucideIcons.alertTriangle,
              color: AppColors.background,
              size: 16,
            ),
            const SizedBox(width: 10),
            Text(
              ok ? 'Settings saved' : 'Save failed — check connection',
              style: const TextStyle(
                color: AppColors.background,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        backgroundColor: ok ? AppColors.textPrimary : AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(24),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Settings',
                    style: Theme.of(context).textTheme.displayMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'System configuration and calibration',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textTertiary,
                        ),
                  ),
                ],
              ),
              const Spacer(),
              if (_hasUnsavedChanges)
                Container(
                  margin: const EdgeInsets.only(right: 16),
                  child: const Text(
                    'Unsaved changes',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: (_hasUnsavedChanges && !_isSaving) ? _saveAll : null,
                  borderRadius: BorderRadius.circular(8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _hasUnsavedChanges
                          ? AppColors.primary
                          : AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow:
                          _hasUnsavedChanges ? AppColors.shadowLow : null,
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                LucideIcons.save,
                                size: 14,
                                color: _hasUnsavedChanges
                                    ? Colors.white
                                    : AppColors.textTertiary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Save All',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _hasUnsavedChanges
                                      ? Colors.white
                                      : AppColors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 36),

          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── NOISE RANGE ──
                  const _SectionHeader(title: 'Threshold Calibration'),
                  const SizedBox(height: 16),
                  _buildNoiseRangeSection(),

                  const SizedBox(height: 32),

                  // ── ALARM PATTERN ──
                  const _SectionHeader(title: 'Alarm Configuration'),
                  const SizedBox(height: 16),
                  _buildAlarmPatternSection(),

                  const SizedBox(height: 32),

                  // ── AI MODEL MANAGEMENT ──
                  const _SectionHeader(title: 'AI Models'),
                  const SizedBox(height: 16),
                  const AiModelManagementSection(),

                  const SizedBox(height: 32),

                  const _SectionHeader(title: 'System Integration'),
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: AppColors.shadowLow,
                    ),
                    child: Column(
                      children: [
                        const _SettingsTile(
                          icon: LucideIcons.database,
                          title: 'Supabase Realtime Database',
                          subtitle:
                              'Primary telemetry storage and synchronization',
                          statusText: 'Connected',
                          isPositive: true,
                        ),
                        Divider(color: AppColors.borderSubtle, height: 1),
                        const _SettingsTile(
                          icon: LucideIcons.radio,
                          title: 'Hardware Nodes',
                          subtitle: 'ESP32 sensor modules deployed in zones',
                          statusText: '3 Online',
                          isPositive: true,
                        ),
                        Divider(color: AppColors.borderSubtle, height: 1),
                        const _SettingsTile(
                          icon: LucideIcons.cpu,
                          title: 'On-Device TFLite Models',
                          subtitle: 'Sound type & noise source classification',
                          statusText: 'Active',
                          isPositive: true,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Noise Range Section ──

  Widget _buildNoiseRangeSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppColors.shadowLow,
      ),
      child: Column(
        children: [
          _SliderRow(
            label: 'Warning Threshold',
            value: _draft.noiseWarningThreshold,
            min: 40,
            max: 80,
            unit: 'dB',
            onChanged: (v) {
              setState(() {
                _draft = _draft.copyWith(noiseWarningThreshold: v);
              });
              _markDirty();
            },
          ),
          const Divider(color: AppColors.borderSubtle, height: 1),
          _SliderRow(
            label: 'Critical Threshold',
            value: _draft.noiseCriticalThreshold,
            min: 60,
            max: 100,
            unit: 'dB',
            onChanged: (v) {
              setState(() {
                _draft = _draft.copyWith(noiseCriticalThreshold: v);
              });
              _markDirty();
            },
          ),
          const Divider(color: AppColors.borderSubtle, height: 1),
          _SliderRow(
            label: 'Temperature Limit',
            value: _draft.tempThreshold,
            min: 20,
            max: 40,
            unit: '°C',
            onChanged: (v) {
              setState(() {
                _draft = _draft.copyWith(tempThreshold: v);
              });
              _markDirty();
            },
          ),
        ],
      ),
    );
  }

  // ── Alarm Pattern Section ──

  Widget _buildAlarmPatternSection() {
    final selectedIndex = _patternValues.indexOf(_draft.alarmPattern);

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppColors.shadowLow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SIGNAL PATTERN',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppColors.textTertiary,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: List.generate(_patternNames.length, (i) {
              final isSelected = i == selectedIndex;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                      right: i < _patternNames.length - 1 ? 8.0 : 0),
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _draft = _draft.copyWith(
                            alarmPattern: _patternValues[i]);
                      });
                      _markDirty();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _patternNames[i],
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? Colors.white
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 24),
          const Divider(color: AppColors.borderSubtle, height: 1),
          const SizedBox(height: 8),
          _SliderRow(
            label: 'Alarm Duration',
            value: _draft.alarmDurationSec,
            min: 1,
            max: 30,
            unit: 's',
            hidePadding: true,
            onChanged: (v) {
              setState(() {
                _draft = _draft.copyWith(alarmDurationSec: v);
              });
              _markDirty();
            },
          ),
          const Divider(color: AppColors.borderSubtle, height: 1),
          _SliderRow(
            label: 'Cooldown Period',
            value: _draft.alarmCooldownSec,
            min: 5,
            max: 120,
            unit: 's',
            hidePadding: true,
            onChanged: (v) {
              setState(() {
                _draft = _draft.copyWith(alarmCooldownSec: v);
              });
              _markDirty();
            },
          ),
        ],
      ),
    );
  }
}

// ── Reusable widgets ──

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String unit;
  final ValueChanged<double> onChanged;
  final bool hidePadding;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    this.hidePadding = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: hidePadding ? 8.0 : 16.0),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppColors.primary,
                inactiveTrackColor: AppColors.surfaceElevated,
                thumbColor: AppColors.primary,
                overlayColor: AppColors.primary.withValues(alpha: 0.1),
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: ((max - min) * 2).toInt(),
                onChanged: onChanged,
              ),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 60,
            child: Text(
              '${value.toStringAsFixed(1)} $unit',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String statusText;
  final bool isPositive;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.statusText,
    required this.isPositive,
  });

  @override
  State<_SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<_SettingsTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: Container(
        color: _isHovered ? AppColors.surfaceElevated : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          children: [
            Icon(widget.icon, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.subtitle,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            if (widget.statusText.isNotEmpty)
              Text(
                widget.statusText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: widget.isPositive
                      ? AppColors.primary
                      : AppColors.textTertiary,
                ),
              ),
            const SizedBox(width: 16),
            const Icon(
              LucideIcons.chevronRight,
              size: 16,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}