import 'dart:async';
import 'dart:math' as math show log, max, min;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/config/zone_names.dart';
import '../../../core/services/supabase/zone_buckets.dart';

// ── School hours (match department_page) ────────────────────
const int _kSchoolStartHour = 7;
const int _kSchoolEndHour = 17;

enum _StatRange { oneHour, threeHours, oneDay }

extension _StatRangeX on _StatRange {
  String get label {
    switch (this) {
      case _StatRange.oneHour:
        return '1H';
      case _StatRange.threeHours:
        return '3H';
      case _StatRange.oneDay:
        return '1D';
    }
  }

  Duration get lookback {
    switch (this) {
      case _StatRange.oneHour:
        return const Duration(hours: 1);
      case _StatRange.threeHours:
        return const Duration(hours: 3);
      case _StatRange.oneDay:
        return const Duration(hours: 10);
    }
  }

  /// Width of one chart point in minutes (readings inside it are averaged).
  /// 1H -> 5-minute points, 3H -> 15-minute points, 1D -> hourly.
  int get bucketMinutes {
    switch (this) {
      case _StatRange.oneHour:
        return 5;
      case _StatRange.threeHours:
        return 15;
      case _StatRange.oneDay:
        return 60;
    }
  }

  /// Distance between the time labels under the chart, in minutes.
  int get labelStepMinutes {
    switch (this) {
      case _StatRange.oneHour:
        return 10;
      case _StatRange.threeHours:
        return 30;
      case _StatRange.oneDay:
        return 60;
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

class _HourlyPoint {
  final int minute; // start of the point, minutes since midnight
  final double noiseDb;
  final double tempC;
  _HourlyPoint(this.minute, this.noiseDb, this.tempC);
}

class _DeptLineStyle {
  final String name;
  final int zoneId;
  final IconData icon;
  final Color color;
  const _DeptLineStyle(this.name, this.zoneId, this.icon, this.color);
}

const _kDeptOrder = [
  _DeptLineStyle(ZoneNames.zone2, 2, LucideIcons.server, AppColors.primary),
  _DeptLineStyle(ZoneNames.zone1, 1, LucideIcons.monitorSpeaker, Color(0xFF10B981)),
  _DeptLineStyle(ZoneNames.zone3, 3, LucideIcons.cpu, Color(0xFFF59E0B)),
];

class StatisticsPage extends StatefulWidget {
  const StatisticsPage({super.key});

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  final _supabase = Supabase.instance.client;
  Timer? _pollTimer;

  _StatRange _range = _StatRange.oneHour;

  bool _loadingA = true;
  String? _errorA;
  List<List<_HourlyPoint>> _hourlyByDept = [[], [], []];
  // x-axis of the charts, in minutes since midnight (follows the selected range)
  double _axisMin = _kSchoolStartHour * 60.0;
  double _axisMax = _kSchoolEndHour * 60.0;

  bool _loadingB = true;
  String? _errorB;
  List<_DeptNoiseStats> _noiseByDept = [];

  bool _loadingC = true;
  String? _errorC;
  _PredictionBundle? _prediction;

  @override
  void initState() {
    super.initState();
    _refreshAll();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _refreshAll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _fetchSectionA(),
      _fetchSectionB(),
      _fetchSectionC(),
    ]);
  }

  Future<List<_HourlyPoint>> _fetchHourlyForZone(int zoneId) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final schoolStart = today.add(const Duration(hours: _kSchoolStartHour));
    final schoolEnd = today.add(const Duration(hours: _kSchoolEndHour));

    DateTime rangeStart = now.subtract(_range.lookback);
    if (_range == _StatRange.oneDay) {
      rangeStart = schoolStart;
    }

    final fetchFrom = rangeStart.isBefore(schoolStart) ? schoolStart : rangeStart;
    final fetchTo = now.isAfter(schoolEnd) ? schoolEnd : now;

    if (fetchFrom.isAfter(fetchTo)) {
      return [];
    }

    // Averaged by Supabase (zone_buckets function) so a busy hour does not
    // hit the API's 1,000-row limit; falls back to reading rows if missing.
    final buckets = await fetchZoneBuckets(
      _supabase,
      zoneId: zoneId,
      from: fetchFrom,
      to: fetchTo,
      bucketMinutes: _range.bucketMinutes,
      firstHour: _kSchoolStartHour,
      endHour: _kSchoolEndHour,
    );

    return buckets.map((b) {
      final db = b.avgRms > 0 ? 20 * (math.log(b.avgRms) / math.log(10)) : 0.0;
      return _HourlyPoint(b.minuteOfDay, db, b.avgTemp);
    }).toList()
      ..sort((a, b) => a.minute.compareTo(b.minute));
  }

  /// [min, max] of the chart x-axis in minutes since midnight: the selected
  /// window (1H / 3H) lined up with the label spacing, or 7 AM–5 PM for 1D.
  List<double> _axisBounds() {
    if (_range == _StatRange.oneDay) {
      return [_kSchoolStartHour * 60.0, _kSchoolEndHour * 60.0];
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final schoolStart = today.add(const Duration(hours: _kSchoolStartHour));
    final schoolEnd = today.add(const Duration(hours: _kSchoolEndHour));
    final rangeStart = now.subtract(_range.lookback);
    final from = rangeStart.isBefore(schoolStart) ? schoolStart : rangeStart;
    final to = now.isAfter(schoolEnd) ? schoolEnd : now;

    final step = _range.labelStepMinutes;
    final fromMin = from.hour * 60 + from.minute;
    final toMin = to.hour * 60 + to.minute;
    final lo = (fromMin ~/ step) * step;
    var hi = ((toMin + step - 1) ~/ step) * step;
    if (hi <= lo) {
      hi = lo + step;
    }
    return [lo.toDouble(), hi.toDouble()];
  }

  Future<void> _fetchSectionA() async {
    try {
      final lists = await Future.wait([
        _fetchHourlyForZone(_kDeptOrder[0].zoneId),
        _fetchHourlyForZone(_kDeptOrder[1].zoneId),
        _fetchHourlyForZone(_kDeptOrder[2].zoneId),
      ]);
      final axis = _axisBounds();
      if (mounted) {
        setState(() {
          _hourlyByDept = lists;
          _axisMin = axis[0];
          _axisMax = axis[1];
          _loadingA = false;
          _errorA = null;
        });
      }
    } catch (e) {
      debugPrint('[Statistics] charts failed: $e');
      if (mounted) {
        setState(() {
          _loadingA = false;
          _errorA = e.toString();
        });
      }
    }
  }

  Future<void> _fetchSectionB() async {
    try {
      final now = DateTime.now();
      final today0 = DateTime(now.year, now.month, now.day);
      final stats = await Future.wait(
        _kDeptOrder.map((d) => _fetchDeptNoiseStats(d, today0, now)),
      );
      if (mounted) {
        setState(() {
          _noiseByDept = stats;
          _loadingB = false;
          _errorB = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingB = false;
          _errorB = e.toString();
        });
      }
    }
  }

  Future<_DeptNoiseStats> _fetchDeptNoiseStats(
    _DeptLineStyle dept,
    DateTime today0,
    DateTime now,
  ) async {
    final rows = await _supabase
        .from('noise_events')
        .select('noise_label, created_at')
        .eq('zone_id', dept.zoneId)
        .gte('created_at', today0.toUtc().toIso8601String())
        .lte('created_at', now.toUtc().toIso8601String());

    final counts = <String, int>{};
    var am = 0;
    var pm = 0;
    for (final row in rows) {
      final label = (row['noise_label'] as String?) ?? 'unknown';
      counts[label] = (counts[label] ?? 0) + 1;
      final h = DateTime.parse(row['created_at'] as String).toLocal().hour;
      if (h < 12) {
        am++;
      } else {
        pm++;
      }
    }

    String? topLabel;
    var topC = 0;
    counts.forEach((k, v) {
      if (v > topC) {
        topC = v;
        topLabel = k;
      }
    });

    return _DeptNoiseStats(
      dept: dept,
      totalEvents: rows.length,
      topLabel: topLabel,
      labelCounts: counts,
      noisiestAm: am >= pm,
    );
  }

  Future<void> _fetchSectionC() async {
    try {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final targetWeekday = tomorrow.weekday;
      final start = DateTime.now().subtract(const Duration(days: 60));

      final rows = await _supabase
          .from('noise_events')
          .select('zone_id, noise_label, rms, created_at')
          .gte('created_at', start.toUtc().toIso8601String())
          .limit(10000);

      final filtered = rows.where((row) {
        final dt = DateTime.parse(row['created_at'] as String).toLocal();
        return dt.weekday == targetWeekday;
      }).toList();

      if (filtered.isEmpty) {
        if (mounted) {
          setState(() {
            _prediction = _PredictionBundle.empty(
              dayName: _weekdayName(targetWeekday),
            );
            _loadingC = false;
            _errorC = null;
          });
        }
        return;
      }

      final days = <String>{};
      for (final row in filtered) {
        final dt = DateTime.parse(row['created_at'] as String).toLocal();
        days.add('${dt.year}-${dt.month}-${dt.day}');
      }
      final dayCount = days.length;

      final byZone = <int, List<Map<String, dynamic>>>{};
      for (final row in filtered) {
        final z = (row['zone_id'] as num).toInt();
        byZone.putIfAbsent(z, () => []).add(row);
      }

      final globalLabelCounts = <String, int>{};
      for (final row in filtered) {
        final lb = (row['noise_label'] as String?) ?? 'unknown';
        globalLabelCounts[lb] = (globalLabelCounts[lb] ?? 0) + 1;
      }
      String? globalTop;
      var gMax = 0;
      globalLabelCounts.forEach((k, v) {
        if (v > gMax) {
          gMax = v;
          globalTop = k;
        }
      });

      final cards = <_PredictionDeptCard>[];
      for (final dept in _kDeptOrder) {
        final zRows = byZone[dept.zoneId] ?? [];
        if (zRows.isEmpty) {
          cards.add(_PredictionDeptCard(
            dept: dept,
            levelLabel: 'Quiet',
            topLabels: const [],
            icon: LucideIcons.checkCircle,
            iconColor: AppColors.success,
          ));
          continue;
        }

        final labelC = <String, int>{};
        final rmsVals = <double>[];
        for (final row in zRows) {
          final lb = (row['noise_label'] as String?) ?? 'unknown';
          labelC[lb] = (labelC[lb] ?? 0) + 1;
          final r = (row['rms'] as num?)?.toDouble();
          if (r != null && r > 0) {
            rmsVals.add(r);
          }
        }

        final avgRms = rmsVals.isEmpty
            ? 0.0
            : rmsVals.reduce((a, b) => a + b) / rmsVals.length;
        final avgDb = avgRms > 0 ? 20 * (math.log(avgRms) / math.log(10)) : 0.0;
        final level = _noiseLevelLabelFromDb(avgDb);

        final sorted = labelC.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final top3 = sorted.take(3).toList();

        final iconData = level == 'Warning'
            ? LucideIcons.alertTriangle
            : level == 'Critical'
                ? LucideIcons.alertOctagon
                : LucideIcons.checkCircle;
        final iconCol = level == 'Warning'
            ? AppColors.warning
            : level == 'Critical'
                ? AppColors.error
                : AppColors.success;

        cards.add(_PredictionDeptCard(
          dept: dept,
          levelLabel: level,
          topLabels: top3,
          icon: iconData,
          iconColor: iconCol,
        ));
      }

      final summary = _buildPredictionSummary(
        totalEvents: filtered.length,
        globalTopLabel: globalTop,
      );
      final conf = _confidenceLabel(dayCount);

      if (mounted) {
        setState(() {
          _prediction = _PredictionBundle(
            dayName: _weekdayName(targetWeekday),
            summary: summary,
            confidenceNote: conf,
            departments: cards,
            matchingDays: dayCount,
          );
          _loadingC = false;
          _errorC = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingC = false;
          _errorC = e.toString();
        });
      }
    }
  }

  static String _weekdayName(int weekday) {
    const names = [
      '',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[weekday];
  }

  static String _noiseLevelLabelFromDb(double db) {
    if (db >= 72) {
      return 'Critical';
    }
    if (db >= 60) {
      return 'Warning';
    }
    if (db >= 45) {
      return 'Normal';
    }
    return 'Quiet';
  }

  static String _buildPredictionSummary({
    required int totalEvents,
    required String? globalTopLabel,
  }) {
    if (globalTopLabel == null) {
      return 'Historical patterns suggest typical library noise levels for this weekday.';
    }
    final label = globalTopLabel.replaceAll('_', ' ');
    if (totalEvents > 40) {
      return 'Based on past data for this weekday, expect elevated noise activity. '
          'The most likely noise type across all departments is $label.';
    }
    if (totalEvents > 15) {
      return 'Based on past weekdays like this one, expect moderate noise activity. '
          'The most likely noise type across all departments is $label.';
    }
    return 'Based on limited history for this weekday, noise may be lighter than average. '
        'The most common noise type observed is $label.';
  }

  static String _confidenceLabel(int uniqueDays) {
    if (uniqueDays >= 10) {
      return 'Prediction confidence: High ($uniqueDays matching days in history)';
    }
    if (uniqueDays >= 4) {
      return 'Prediction confidence: Medium ($uniqueDays matching days in history)';
    }
    return 'Prediction confidence: Low (only $uniqueDays matching days found)';
  }

  void _onRangeChanged(_StatRange r) {
    setState(() {
      _range = r;
      _loadingA = true;
    });
    _fetchSectionA();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Statistics', style: Theme.of(context).textTheme.displayMedium),
            const SizedBox(height: 4),
            Text(
              'Cross-department trends, noise patterns, and forecasts',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textTertiary,
                  ),
            ),
            const SizedBox(height: 28),
            _sectionA(context),
            const SizedBox(height: 28),
            _sectionB(context),
            const SizedBox(height: 28),
            _sectionC(context),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _sectionA(BuildContext context) {
    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'General report: combined department graphs',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              _rangeToggle(),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Sound Level — All Departments',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 260,
            child: _loadingA
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                : _errorA != null
                    ? Center(child: Text(_errorA!, style: const TextStyle(color: AppColors.textTertiary, fontSize: 13)))
                    : _multiLineChart(isSound: true),
          ),
          const SizedBox(height: 8),
          _legendRow(),
          const SizedBox(height: 28),
          Text(
            'Temperature — All Departments',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 260,
            child: _loadingA
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                : _errorA != null
                    ? const SizedBox.shrink()
                    : _multiLineChart(isSound: false),
          ),
          const SizedBox(height: 8),
          _legendRow(),
        ],
      ),
    );
  }

  Widget _rangeToggle() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _StatRange.values.map((r) {
          final sel = _range == r;
          return GestureDetector(
            onTap: () => _onRangeChanged(r),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: sel ? AppColors.surfaceHighlight.withValues(alpha: 0.85) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                r.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: sel ? AppColors.textPrimary : AppColors.textTertiary,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _legendRow() {
    return Wrap(
      spacing: 20,
      runSpacing: 8,
      children: _kDeptOrder
          .map(
            (d) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: d.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  d.name,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          )
          .toList(),
    );
  }

  Widget _multiLineChart({required bool isSound}) {
    final anyData = _hourlyByDept.any((l) => l.isNotEmpty);
    if (!anyData) {
      return _emptyChartBody();
    }

    final minX = _axisMin;
    final maxX = _axisMax;

    List<FlSpot> spotsFor(List<_HourlyPoint> pts, bool sound) {
      return pts
          .map(
            (p) => FlSpot(
              p.minute.toDouble(),
              sound ? p.noiseDb : p.tempC,
            ),
          )
          .toList();
    }

    final barData = <LineChartBarData>[];
    final barDeptNames = <String>[];
    for (var i = 0; i < _kDeptOrder.length; i++) {
      final pts = _hourlyByDept[i];
      final spots = spotsFor(pts, isSound);
      if (spots.isEmpty) {
        continue;
      }
      final color = _kDeptOrder[i].color;
      barDeptNames.add(_kDeptOrder[i].name);
      barData.add(
        LineChartBarData(
          spots: spots,
          isCurved: spots.length > 2,
          curveSmoothness: 0.25,
          color: color,
          barWidth: 2.5,
          dotData: FlDotData(
            show: spots.length <= 4,
            getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
              radius: 3,
              color: color,
              strokeWidth: 1.5,
              strokeColor: AppColors.surface,
            ),
          ),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withValues(alpha: 0.12),
                color.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      );
    }

    if (barData.isEmpty) {
      return _emptyChartBody();
    }

    final minY = isSound ? 0.0 : 20.0;
    final maxY = isSound ? 100.0 : 40.0;
    final interval = isSound ? 20.0 : 5.0;
    final leftSuffix = isSound ? ' dB' : ' °C';

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: interval,
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
              interval: _range.labelStepMinutes.toDouble(),
              getTitlesWidget: (value, meta) {
                if (value > maxX) {
                  return const SizedBox();
                }
                final label = _clockLabel(value.round());
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    label,
                    style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: interval,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()}$leftSuffix',
                style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
              ),
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        minX: minX,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        lineBarsData: barData,
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppColors.surfaceHighlight,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((s) {
                final barIndex = s.barIndex;
                final deptName = barIndex >= 0 && barIndex < barDeptNames.length
                    ? barDeptNames[barIndex]
                    : '';
                final timeLabel = _clockFull(s.x.round());
                final yLabel = isSound ? '${s.y.toStringAsFixed(1)} dB' : '${s.y.toStringAsFixed(1)} °C';
                return LineTooltipItem(
                  '$timeLabel\n$deptName\n$yLabel',
                  const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }

  Widget _emptyChartBody() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.barChart2, size: 32, color: AppColors.textTertiary),
          const SizedBox(height: 12),
          Text(
            'No school-hour data yet (7 AM – 5 PM)',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _sectionB(BuildContext context) {
    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Noise Frequency by Department',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            'Which department is noisiest and what type of noise occurs most',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 20),
          if (_loadingB)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
              ),
            )
          else if (_errorB != null)
            Text(_errorB!, style: const TextStyle(color: AppColors.textTertiary, fontSize: 13))
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _noiseByDept.map((s) => Expanded(child: _noiseDeptCard(context, s))).toList(),
            ),
        ],
      ),
    );
  }

  Widget _noiseDeptCard(BuildContext context, _DeptNoiseStats s) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(s.dept.icon, size: 18, color: s.dept.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.dept.name,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${s.totalEvents} events today',
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 10),
            if (s.topLabel != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: s.dept.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  s.topLabel!.replaceAll('_', ' '),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: s.dept.color),
                ),
              )
            else
              const Text('—', style: TextStyle(color: AppColors.textTertiary)),
            const SizedBox(height: 14),
            SizedBox(
              height: 160,
              child: s.labelCounts.isEmpty
                  ? _emptyChartBody()
                  : _miniBarChart(s),
            ),
            const SizedBox(height: 10),
            Text(
              'Noisiest: ${s.noisiestAm ? 'AM' : 'PM'}',
              style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniBarChart(_DeptNoiseStats s) {
    final entries = s.labelCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final take = entries.length > 6 ? 6 : entries.length;
    final top = entries.take(take).toList();

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: top.map((e) => e.value).reduce((a, b) => a > b ? a : b).toDouble() * 1.2 + 1,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          show: true,
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 56,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= top.length) {
                  return const SizedBox();
                }
                final raw = top[i].key.replaceAll('_', ' ');
                final short = raw.length > 10 ? '${raw.substring(0, 9)}…' : raw;
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Transform.rotate(
                    angle: -0.785,
                    child: Text(
                      short,
                      style: const TextStyle(fontSize: 9, color: AppColors.textTertiary),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: List.generate(top.length, (i) {
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: top[i].value.toDouble(),
                width: 14,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                color: s.dept.color,
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _sectionC(BuildContext context) {
    return _sectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Tomorrow's Prediction",
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          if (_loadingC)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary)),
            )
          else if (_errorC != null)
            Text(_errorC!, style: const TextStyle(color: AppColors.textTertiary))
          else if (_prediction != null) ...[
            if (_prediction!.isEmpty) ...[
              Text(
                'Not enough historical data for ${_prediction!.dayName}. '
                'Check back after a few weeks of monitoring.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
              ),
            ] else ...[
              Text(
                'Based on historical patterns for ${_prediction!.dayName}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textTertiary),
              ),
              const SizedBox(height: 16),
              Text(
                _prediction!.summary,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppColors.textPrimary,
                      fontStyle: FontStyle.italic,
                    ),
              ),
              const SizedBox(height: 20),
              ..._prediction!.departments.map((c) => _predictionDeptTile(context, c)),
              const SizedBox(height: 16),
              Text(
                _prediction!.confidenceNote,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textTertiary),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _predictionDeptTile(BuildContext context, _PredictionDeptCard c) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(c.icon, color: c.iconColor, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.dept.name,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  'Predicted level: ${c.levelLabel}',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(c.topLabels.length, (i) {
                    final e = c.topLabels[i];
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${i + 1}. ${e.key.replaceAll('_', ' ')} × ${e.value}',
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard(BuildContext context, {required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppColors.shadowLow,
      ),
      child: child,
    );
  }
}

// ── Section B model ───────────────────────────────────────────

class _DeptNoiseStats {
  final _DeptLineStyle dept;
  final int totalEvents;
  final String? topLabel;
  final Map<String, int> labelCounts;
  final bool noisiestAm;

  _DeptNoiseStats({
    required this.dept,
    required this.totalEvents,
    required this.topLabel,
    required this.labelCounts,
    required this.noisiestAm,
  });
}

// ── Section C models ──────────────────────────────────────────

class _PredictionBundle {
  final String dayName;
  final String summary;
  final String confidenceNote;
  final List<_PredictionDeptCard> departments;
  final int matchingDays;
  final bool isEmpty;

  _PredictionBundle({
    required this.dayName,
    required this.summary,
    required this.confidenceNote,
    required this.departments,
    required this.matchingDays,
    this.isEmpty = false,
  });

  factory _PredictionBundle.empty({required String dayName}) {
    return _PredictionBundle(
      dayName: dayName,
      summary: '',
      confidenceNote: '',
      departments: const [],
      matchingDays: 0,
      isEmpty: true,
    );
  }
}

class _PredictionDeptCard {
  final _DeptLineStyle dept;
  final String levelLabel;
  final List<MapEntry<String, int>> topLabels;
  final IconData icon;
  final Color iconColor;

  _PredictionDeptCard({
    required this.dept,
    required this.levelLabel,
    required this.topLabels,
    required this.icon,
    required this.iconColor,
  });
}