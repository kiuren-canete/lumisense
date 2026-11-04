import 'dart:math' as math show log, max, min;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/config/zone_names.dart';
import '../../dashboard/presentation/widgets/summary_panel.dart';

// ─────────────────────────────────────────────────────────────
//  CONSTANTS
// ─────────────────────────────────────────────────────────────
const int _kSchoolStartHour = 7;   // 7:00 AM
const int _kSchoolEndHour   = 17;  // 5:00 PM  (exclusive upper bound)

/// Range filter options shown in the top-right button group.
enum _Range { oneHour, threeHours, oneDay }

extension _RangeExt on _Range {
  String get label {
    switch (this) {
      case _Range.oneHour:    return '1 Hour';
      case _Range.threeHours: return '3 Hours';
      case _Range.oneDay:     return '1 Day';
    }
  }

  /// How far back from NOW we fetch data.
  Duration get lookback {
    switch (this) {
      case _Range.oneHour:    return const Duration(hours: 1);
      case _Range.threeHours: return const Duration(hours: 3);
      case _Range.oneDay:     return const Duration(hours: 10); // 7AM–5PM span
    }
  }

  /// Width of one chart point in minutes (readings inside it are averaged).
  /// 1 Hour -> 5-minute points, 3 Hours -> 15-minute points, 1 Day -> hourly.
  int get bucketMinutes {
    switch (this) {
      case _Range.oneHour:    return 5;
      case _Range.threeHours: return 15;
      case _Range.oneDay:     return 60;
    }
  }

  /// Distance between the time labels under the chart, in minutes.
  int get labelStepMinutes {
    switch (this) {
      case _Range.oneHour:    return 10;
      case _Range.threeHours: return 30;
      case _Range.oneDay:     return 60;
    }
  }
}

/// "7AM", "11:10AM", "12:30PM". [minute] = minutes since midnight.
String _clockLabel(int minute) {
  final h24 = minute ~/ 60;
  final m = minute % 60;
  final suffix = h24 >= 12 ? 'PM' : 'AM';
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  return m == 0
      ? '$h12$suffix'
      : '$h12:${m.toString().padLeft(2, '0')}$suffix';
}

/// "7:00 AM", "11:10 AM" (for the chart tooltip).
String _clockFull(int minute) {
  final h24 = minute ~/ 60;
  final m = minute % 60;
  final suffix = h24 >= 12 ? 'PM' : 'AM';
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  return '$h12:${m.toString().padLeft(2, '0')} $suffix';
}

// ─────────────────────────────────────────────────────────────
//  DATA MODEL  (one averaged point per hour slot)
// ─────────────────────────────────────────────────────────────
class _HourlyPoint {
  final int minute;     // start of the point, minutes since midnight
  final double noiseDb;
  final double tempC;
  _HourlyPoint(this.minute, this.noiseDb, this.tempC);
}

// ─────────────────────────────────────────────────────────────
//  PAGE
// ─────────────────────────────────────────────────────────────
class DepartmentPage extends StatefulWidget {
  const DepartmentPage({super.key});

  @override
  State<DepartmentPage> createState() => _DepartmentPageState();
}

class _DepartmentPageState extends State<DepartmentPage> {
  final _supabase = Supabase.instance.client;

  int _selectedTab = 0;
  _Range _selectedRange = _Range.oneHour;

  // zone_id values that match Supabase seeds: 1=IT, 2=CS, 3=Eng
  static const _departments = [
    _DeptInfo(ZoneNames.zone1,          1, LucideIcons.monitorSpeaker),
    _DeptInfo(ZoneNames.zone2,          2, LucideIcons.server),
    _DeptInfo(ZoneNames.zone3,          3, LucideIcons.cpu),
  ];

  // ── live chart data ──────────────────────────────────────
  List<_HourlyPoint> _chartPoints = [];
  // x-axis of the chart, in minutes since midnight (follows the selected range)
  double _axisMin = _kSchoolStartHour * 60.0;
  double _axisMax = _kSchoolEndHour * 60.0;
  bool _loading = true;
  String? _error;

  // ── current stats strip (latest reading for the zone) ───
  double _latestDb   = 0;
  double _latestTemp = 0;
  String _latestType = '—';
  String _latestStatus = 'Quiet';
  int    _amCount  = 0;
  int    _pmCount  = 0;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  // Re-fetch whenever tab or range changes
  void _onTabChanged(int i) {
    setState(() { _selectedTab = i; _loading = true; _error = null; });
    _fetchData();
  }

  void _onRangeChanged(_Range r) {
    setState(() { _selectedRange = r; _loading = true; _error = null; });
    _fetchData();
  }

  // ─────────────────────────────────────────────────────────
  //  FETCH  — queries sensor_readings for the selected zone
  //  within:
  //    • the lookback window (1h / 3h / full day)
  //    • school hours 7:00 AM – 5:00 PM on the same calendar day
  //  Then buckets rows into hourly averages.
  // ─────────────────────────────────────────────────────────
  Future<void> _fetchData() async {
    final dept   = _departments[_selectedTab];
    final zoneId = dept.zoneId;

    try {
      final now   = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // School-hours window for today
      final schoolStart = today.add(const Duration(hours: _kSchoolStartHour));
      final schoolEnd   = today.add(const Duration(hours: _kSchoolEndHour));

      // Lookback window
      DateTime rangeStart = now.subtract(_selectedRange.lookback);

      // For "1 Day" we show the entire school day from 7 AM
      if (_selectedRange == _Range.oneDay) {
        rangeStart = schoolStart;
      }

      // Effective window = intersection of lookback and school hours
      final fetchFrom = rangeStart.isBefore(schoolStart) ? schoolStart : rangeStart;
      final fetchTo   = now.isAfter(schoolEnd) ? schoolEnd : now;

      if (fetchFrom.isAfter(fetchTo)) {
        // Outside school hours right now — show empty state
        if (mounted) setState(() { _chartPoints = []; _loading = false; });
        return;
      }

      // Cap rows ~1 Hz sampling (with headroom); 1 Day needs far more than 7.2k rows.
      final spanSecs = math.max(1, fetchTo.difference(fetchFrom).inSeconds);
      final rowLimit = math.min(65535, math.max(8000, spanSecs + 4096));

      // Query Supabase — bucket client-side by school hour.
      final rows = await _supabase
          .from('sensor_readings')
          .select('rms, temperature_c, created_at')
          .eq('zone_id', zoneId)
          .gte('created_at', fetchFrom.toIso8601String())
          .lte('created_at', fetchTo.toIso8601String())
          .order('created_at', ascending: true)
          .limit(rowLimit);

      // ── Bucket into hour slots ───────────────────────────
      // Key = hour of day (7..16). Each bucket accumulates rms & temp.
      final Map<int, List<double>> rmsByHour  = {};
      final Map<int, List<double>> tempByHour = {};

      for (final row in rows) {
        final ts   = DateTime.parse(row['created_at'] as String).toLocal();
        final hour = ts.hour;
        if (hour < _kSchoolStartHour || hour >= _kSchoolEndHour) continue;
        final step = _selectedRange.bucketMinutes;
        final bucket = ((hour * 60 + ts.minute) ~/ step) * step;
        final double rms  = (row['rms']           as num?)?.toDouble() ?? 0;
        final double temp = (row['temperature_c'] as num?)?.toDouble() ?? 0;
        rmsByHour .putIfAbsent(bucket, () => []).add(rms);
        tempByHour.putIfAbsent(bucket, () => []).add(temp);
      }

      // Convert to _HourlyPoint list — only hours that have data
      final points = rmsByHour.keys.map((bucket) {
        final avgRms  = rmsByHour[bucket]!.reduce((a, b) => a + b) / rmsByHour[bucket]!.length;
        final avgTemp = tempByHour[bucket]!.reduce((a, b) => a + b) / tempByHour[bucket]!.length;
        final db      = avgRms > 0 ? 20 * (math.log(avgRms) / math.log(10)) : 0.0;
        return _HourlyPoint(bucket, db, avgTemp);
      }).toList()
        ..sort((a, b) => a.minute.compareTo(b.minute));

      // x-axis = the selected window, lined up with the label spacing
      final labelStep = _selectedRange.labelStepMinutes;
      final fromMin = fetchFrom.hour * 60 + fetchFrom.minute;
      final toMin   = fetchTo.hour * 60 + fetchTo.minute;
      var axisMin = (fromMin ~/ labelStep) * labelStep;
      var axisMax = ((toMin + labelStep - 1) ~/ labelStep) * labelStep;
      if (_selectedRange == _Range.oneDay) {
        axisMin = _kSchoolStartHour * 60;
        axisMax = _kSchoolEndHour * 60;
      }
      if (axisMax <= axisMin) axisMax = axisMin + labelStep;

      // ── AM / PM counts (noise_events for today) ──────────
      final today0 = DateTime(now.year, now.month, now.day);
      final events = await _supabase
          .from('noise_events')
          .select('created_at')
          .eq('zone_id', zoneId)
          .gte('created_at', today0.toIso8601String())
          .lte('created_at', now.toIso8601String());

      int am = 0, pm = 0;
      for (final e in events) {
        final h = DateTime.parse(e['created_at'] as String).toLocal().hour;
        if (h < 12) {
          am++;
        } else {
          pm++;
        }
      }

      // ── Latest reading for the stats strip ───────────────
      final latest = rows.isNotEmpty ? rows.last : null;
      double latestDb   = 0;
      double latestTemp = 0;
      if (latest != null) {
        final rms = (latest['rms'] as num?)?.toDouble() ?? 0;
        latestDb   = rms > 0 ? 20 * (math.log(rms) / math.log(10)) : 0;
        latestTemp = (latest['temperature_c'] as num?)?.toDouble() ?? 0;
      }

      if (mounted) {
        setState(() {
          _chartPoints  = points;
          _axisMin      = axisMin.toDouble();
          _axisMax      = axisMax.toDouble();
          _latestDb     = latestDb;
          _latestTemp   = latestTemp;
          _latestType   = rows.isNotEmpty ? 'Ambient' : '—';
          _latestStatus = latestDb >= 72 ? 'Critical'
                        : latestDb >= 60 ? 'Warning'
                        : latestDb >= 45 ? 'Stable'
                        : 'Quiet';
          _amCount      = am;
          _pmCount      = pm;
          _loading      = false;
          _error        = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _loading = false; _error = e.toString(); });
      }
    }
  }

  // ─────────────────────────────────────────────────────────
  //  BUILD
  // ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final dept = _departments[_selectedTab];

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ────────────────────────────────────────
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Department',
                      style: Theme.of(context).textTheme.displayMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Real-time monitoring · 7:00 AM – 5:00 PM',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textTertiary),
                  ),
                ],
              ),
              const Spacer(),
              // ── Range selector (1H / 3H / 1D) ─────────────
              _RangeSelector(
                selected: _selectedRange,
                onChanged: _onRangeChanged,
              ),
            ],
          ),

          const SizedBox(height: 24),
          _buildTabBar(),
          const SizedBox(height: 24),

          // ── Content ───────────────────────────────────────
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left: chart + stats strip
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(
                        flex: 3,
                        child: _buildChartCard(context, dept),
                      ),
                      const SizedBox(height: 16),
                      _buildCurrentDataRow(context),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Right: summary panel + env button
                Expanded(
                  flex: 1,
                  child: Column(
                    children: [
                      const Expanded(child: SummaryPanel()),
                      const SizedBox(height: 16),
                      _buildEnvSummaryButton(context, dept),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  //  TAB BAR
  // ─────────────────────────────────────────────────────────
  Widget _buildTabBar() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(_departments.length, (i) {
          final d          = _departments[i];
          final isSelected = i == _selectedTab;
          return GestureDetector(
            onTap: () => _onTabChanged(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.surfaceHighlight.withValues(alpha: 0.85)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isSelected) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppColors.textPrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Icon(d.icon,
                      size: 16,
                      color: isSelected
                          ? AppColors.textPrimary
                          : AppColors.textTertiary),
                  const SizedBox(width: 8),
                  Text(
                    d.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? AppColors.textPrimary
                          : AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  //  CHART CARD
  // ─────────────────────────────────────────────────────────
  Widget _buildChartCard(BuildContext context, _DeptInfo dept) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Chart header
          Row(
            children: [
              Icon(dept.icon, size: 18, color: AppColors.textTertiary),
              const SizedBox(width: 10),
              Text(
                '${dept.name} — Sound Level (${_selectedRange.label})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              // Live badge
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.radio, size: 12, color: AppColors.success),
                    SizedBox(width: 6),
                    Text('Live',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.success,
                        )),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Chart body
          Expanded(child: _buildChartBody()),
        ],
      ),
    );
  }

  Widget _buildChartBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.primary,
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(
          'Failed to load data',
          style: const TextStyle(color: AppColors.textTertiary, fontSize: 13),
        ),
      );
    }

    if (_chartPoints.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.barChart2,
                size: 32, color: AppColors.textTertiary),
            const SizedBox(height: 12),
            Text(
              _isOutsideSchoolHours()
                  ? 'No school-hour data yet (7 AM – 5 PM)'
                  : 'No data in the selected range',
              style: const TextStyle(
                  color: AppColors.textTertiary, fontSize: 13),
            ),
          ],
        ),
      );
    }

    // Build FlSpot list — x = minutes since midnight, y = dB
    final spots = _chartPoints
        .map((p) => FlSpot(p.minute.toDouble(), p.noiseDb))
        .toList();

    // X-axis = the selected window (1 Hour / 3 Hours / 7 AM–5 PM)
    final double minX = _axisMin;
    final double maxX = _axisMax;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 20,
          getDrawingHorizontalLine: (_) => FlLine(
            color: AppColors.surfaceHighlight.withValues(alpha: 0.5),
            strokeWidth: 1,
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              interval: _selectedRange.labelStepMinutes.toDouble(),
              getTitlesWidget: (value, meta) {
                if (value > maxX) return const SizedBox();
                final label = _clockLabel(value.round());
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    label,
                    style: const TextStyle(
                        color: AppColors.textTertiary, fontSize: 11),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: 20,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()} dB',
                style: const TextStyle(
                    color: AppColors.textTertiary, fontSize: 11),
              ),
            ),
          ),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        minX: minX,
        maxX: maxX,
        minY: 0,
        maxY: 100,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: spots.length > 2,
            curveSmoothness: 0.25,
            color: AppColors.primary,
            barWidth: 2.5,
            // Show dots only when few points (sparse data)
            dotData: FlDotData(
              show: spots.length <= 4,
              getDotPainter: (spot, percent, bar, index) =>
                  FlDotCirclePainter(
                radius: 4,
                color: AppColors.primary,
                strokeWidth: 2,
                strokeColor: AppColors.surface,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  AppColors.primary.withValues(alpha: 0.15),
                  AppColors.primary.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppColors.surfaceHighlight,
            getTooltipItems: (touchedSpots) => touchedSpots.map((s) {
              final label = _clockFull(s.x.round());
              return LineTooltipItem(
                '$label\n${s.y.toStringAsFixed(1)} dB',
                const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  bool _isOutsideSchoolHours() {
    final now = DateTime.now();
    return now.hour < _kSchoolStartHour || now.hour >= _kSchoolEndHour;
  }

  // ─────────────────────────────────────────────────────────
  //  STATS STRIP
  // ─────────────────────────────────────────────────────────
  Widget _buildCurrentDataRow(BuildContext context) {
    final statusColor = _latestStatus == 'Critical'
        ? AppColors.error
        : _latestStatus == 'Warning'
            ? AppColors.warning
            : _latestStatus == 'Stable'
                ? AppColors.primary
                : AppColors.success;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _CurrentDataItem(
              icon: LucideIcons.activity,
              label: 'Status',
              value: _latestStatus,
              color: statusColor),
          _divider(),
          _CurrentDataItem(
              icon: LucideIcons.waves,
              label: 'Type',
              value: _latestType,
              color: AppColors.textPrimary),
          _divider(),
          _CurrentDataItem(
              icon: LucideIcons.volume2,
              label: 'Sound',
              value: _latestDb > 0
                  ? '${_latestDb.toStringAsFixed(1)} dB'
                  : '—',
              color: AppColors.primary),
          _divider(),
          _CurrentDataItem(
              icon: LucideIcons.thermometer,
              label: 'Temp',
              value: _latestTemp > 0
                  ? '${_latestTemp.toStringAsFixed(1)}°C'
                  : '—',
              color: AppColors.success),
          _divider(),
          _CurrentDataItem(
              icon: LucideIcons.sunrise,
              label: 'AM Count',
              value: '$_amCount',
              color: AppColors.textSecondary),
          _divider(),
          _CurrentDataItem(
              icon: LucideIcons.sunset,
              label: 'PM Count',
              value: '$_pmCount',
              color: AppColors.textSecondary),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 40,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        color: AppColors.surfaceHighlight,
      );

  // ─────────────────────────────────────────────────────────
  //  ENV SUMMARY BUTTON
  // ─────────────────────────────────────────────────────────
  Widget _buildEnvSummaryButton(BuildContext context, _DeptInfo dept) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showEnvironmentalSummary(context, dept),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.surfaceHighlight,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppColors.shadowHeavy.withValues(alpha: 0.3),
                blurRadius: 16,
                spreadRadius: -8,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.fileText,
                  size: 16, color: AppColors.textPrimary),
              SizedBox(width: 10),
              Text(
                'View Environmental Summary',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEnvironmentalSummary(BuildContext context, _DeptInfo dept) {
    // Compute dominant condition from chart data
    double avgDb = 0;
    if (_chartPoints.isNotEmpty) {
      avgDb = _chartPoints.map((p) => p.noiseDb).reduce((a, b) => a + b) /
          _chartPoints.length;
    }
    final condition = avgDb >= 72
        ? 'Critical'
        : avgDb >= 60
            ? 'Warning'
            : avgDb >= 45
                ? 'Normal'
                : 'Quiet';

    final peakTemp = _chartPoints.isNotEmpty
        ? _chartPoints.map((p) => p.tempC).reduce((a, b) => a > b ? a : b)
        : _latestTemp;

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (context) => _EnvironmentalSummaryDialog(
        departmentName: dept.name,
        rangeLabel: _selectedRange.label,
        dominantCondition: condition,
        peakTemp: peakTemp,
        noisyAlerts: _amCount + _pmCount,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  RANGE SELECTOR WIDGET
// ─────────────────────────────────────────────────────────────
class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.selected, required this.onChanged});

  final _Range selected;
  final ValueChanged<_Range> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.workspaceBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _Range.values.map((r) {
          final isSelected = r == selected;
          return GestureDetector(
            onTap: () => onChanged(r),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.textPrimary
                    : AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                r.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isSelected
                      ? AppColors.appBackground
                      : AppColors.textSecondary,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  SUPPORTING WIDGETS + MODELS
// ─────────────────────────────────────────────────────────────
class _DeptInfo {
  final String name;
  final int    zoneId;
  final IconData icon;
  const _DeptInfo(this.name, this.zoneId, this.icon);
}

class _CurrentDataItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _CurrentDataItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: AppColors.textTertiary),
              const SizedBox(width: 5),
              Text(label,
                  style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textTertiary,
                      fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  ENVIRONMENTAL SUMMARY DIALOG
// ─────────────────────────────────────────────────────────────
class _EnvironmentalSummaryDialog extends StatelessWidget {
  final String departmentName;
  final String rangeLabel;
  final String dominantCondition;
  final double peakTemp;
  final int    noisyAlerts;

  const _EnvironmentalSummaryDialog({
    required this.departmentName,
    required this.rangeLabel,
    required this.dominantCondition,
    required this.peakTemp,
    required this.noisyAlerts,
  });

  @override
  Widget build(BuildContext context) {
    final remarks = noisyAlerts == 0
        ? 'The environment was calm throughout the selected period. '
          'No interventions were required.'
        : noisyAlerts <= 3
            ? 'Conditions were generally manageable. A few incidents were '
              'recorded — targeted reminders may further improve discipline.'
            : 'Multiple noise incidents were recorded. Consider increasing '
              'monitoring frequency or deploying additional reminders.';

    return Dialog(
      backgroundColor: AppColors.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 520,
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surfaceHighlight,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Environmental Summary Report',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Department: $departmentName  ·  Range: $rangeLabel',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            Row(children: [
              Expanded(
                  child: _DataCell(
                      label: 'Dominant room condition',
                      value: dominantCondition)),
              const SizedBox(width: 12),
              Expanded(
                  child: _DataCell(
                      label: 'Peak temperature',
                      value: peakTemp > 0
                          ? '${peakTemp.toStringAsFixed(1)}°C'
                          : '—')),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: _DataCell(
                      label: 'Noisy alerts recorded',
                      value: '$noisyAlerts')),
              const SizedBox(width: 12),
              Expanded(
                  child: _DataCell(
                      label: 'School hours window',
                      value: '7:00 AM – 5:00 PM')),
            ]),

            const SizedBox(height: 24),
            Text('Explanation',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              'During the selected range ($rangeLabel), the monitored '
              'environment was mostly $dominantCondition. Peak temperature '
              'reached ${peakTemp > 0 ? "${peakTemp.toStringAsFixed(1)}°C" : "N/A"} '
              'and $noisyAlerts noisy alert${noisyAlerts == 1 ? "" : "s"} were recorded.',
              style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.6),
            ),
            const SizedBox(height: 20),
            Text('Remarks / Observation',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              remarks,
              style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.6),
            ),
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  backgroundColor: AppColors.surfaceHighlight,
                  foregroundColor: AppColors.textPrimary,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Close',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DataCell extends StatelessWidget {
  final String label;
  final String value;
  const _DataCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textTertiary,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text(value,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}