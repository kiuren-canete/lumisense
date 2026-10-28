import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/config/zone_names.dart';

import '../../../../core/domain/entities/zone_snapshot.dart';
import '../../../../core/domain/value_objects/noise_level.dart';

class FloorPlanWidget extends StatefulWidget {
  const FloorPlanWidget({super.key, this.liveZones});
  
  final List<ZoneSnapshot>? liveZones;

  @override
  State<FloorPlanWidget> createState() => _FloorPlanWidgetState();
}

class _ZoneConfig {
  final int id;
  final String title;
  final double x;
  final double y;

  const _ZoneConfig({
    required this.id,
    required this.title,
    required this.x,
    required this.y,
  });
}

// Coordinates are normalized (0..1) against the floor plan area and were
// picked to land the sensor point on the center of each of the 3 tables
// in assets/images/map_main.png (top table, left table, bottom table).
const _zones = [
  _ZoneConfig(id: 1, title: ZoneNames.zone1, x: 0.50, y: 0.21),
  _ZoneConfig(id: 2, title: ZoneNames.zone2, x: 0.19, y: 0.53),
  _ZoneConfig(id: 3, title: ZoneNames.zone3, x: 0.50, y: 0.76),
];

// Native pixel dimensions of assets/images/map_main.png. Used so the floor
// plan is always contain-fit (never cropped) inside its box. If the image
// asset is ever swapped for one with different dimensions, update these two
// numbers to match its actual pixel width/height.
const double _mapImageWidth = 1532;
const double _mapImageHeight = 1027;
const double _mapAspectRatio = _mapImageWidth / _mapImageHeight;

/// The largest rect of size matching [aspectRatio] that fits inside a
/// [boxWidth] x [boxHeight] box, centered — the same math BoxFit.contain
/// uses internally. Exposed here so sibling widgets (the pins) can be laid
/// out in the exact same coordinate space as the image.
class _FitRect {
  const _FitRect(this.left, this.top, this.width, this.height);
  final double left;
  final double top;
  final double width;
  final double height;
}

_FitRect _containRect(double boxWidth, double boxHeight, double aspectRatio) {
  final boxAspect = boxWidth / boxHeight;
  double width;
  double height;
  if (boxAspect > aspectRatio) {
    // Box is relatively wider than the image -> height is the limiting side.
    height = boxHeight;
    width = height * aspectRatio;
  } else {
    // Box is relatively taller/narrower than the image -> width is limiting.
    width = boxWidth;
    height = width / aspectRatio;
  }
  return _FitRect((boxWidth - width) / 2, (boxHeight - height) / 2, width, height);
}

class _FloorPlanWidgetState extends State<FloorPlanWidget> {
  final _rng = Random(42);
  Timer? _timer;
  final Map<int, _AiEvent> _demoEvents = {};

  bool get _useDemoData {
    return widget.liveZones == null || widget.liveZones!.isEmpty;
  }

  @override
  void initState() {
    super.initState();
    // Keep demo data spinning just in case it's used
    for (final z in _zones) {
      _demoEvents[z.id] = _AiEvent.random(_rng);
    }
    
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      if (_useDemoData) {
        setState(() {
          final targetId = _zones[_rng.nextInt(_zones.length)].id;
          _demoEvents[targetId] = _AiEvent.random(_rng);
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  IconData _getIconForClass(String soundClass) {
    switch (soundClass.toLowerCase()) {
      case 'ambient':
      case 'background noise':
      case 'quiet':
        return LucideIcons.wind;
      case 'conversation':
      case 'talking':
        return LucideIcons.messageCircle;
      case 'laughing':
      case 'laughter':
        return LucideIcons.smile;
      case 'shouting':
        return LucideIcons.megaphone;
      case 'clap':
      case 'clapping':
        return LucideIcons.hand;
      case 'table dragging':
      case 'chair drag':
      case 'furniture_dragging':
      case 'table_dragging':
        return LucideIcons.armchair;
      case 'object drop':
        return LucideIcons.box;
      case 'ring phone':
      case 'phone_ringing':
      case 'phone':
        return LucideIcons.phoneCall;
      case 'notification':
        return LucideIcons.bell;
      default:
        return LucideIcons.activity;
    }
  }

  _AiSeverity _getSeverityForLevel(NoiseLevel level) {
    switch (level) {
      case NoiseLevel.quiet:
      case NoiseLevel.normal:
        return _AiSeverity.low;
      case NoiseLevel.warning:
        return _AiSeverity.medium;
      case NoiseLevel.critical:
        return _AiSeverity.high;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<int, _AiEvent> currentEvents = {};
    
    if (!_useDemoData) {
      for (final snapshot in widget.liveZones!) {
        final zId = int.tryParse(snapshot.zoneId) ?? 0;
        currentEvents[zId] = _AiEvent(
          x: 0, y: 0, // Not used by ZoneMarker directly anymore
          label: snapshot.soundClass,
          icon: _getIconForClass(snapshot.soundClass),
          severity: _getSeverityForLevel(snapshot.noiseLevel),
          db: snapshot.noiseDb,
          isInactive: snapshot.isInactive,
        );
      }
    } else {
      currentEvents.addAll(_demoEvents);
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppColors.shadowLow,
      ),
      child: SizedBox.expand(
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Compute the largest rect that fits the image's native
                    // aspect ratio inside the available space without
                    // cropping (like BoxFit.contain), so the whole floor
                    // plan is always visible no matter the window size or
                    // future edits to the image's own dimensions.
                    final rect = _containRect(
                      constraints.maxWidth,
                      constraints.maxHeight,
                      _mapAspectRatio,
                    );

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Floor Plan Background (room layout with the 3
                        // sensor tables), sized to the fitted rect.
                        Positioned(
                          left: rect.left,
                          top: rect.top,
                          width: rect.width,
                          height: rect.height,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.asset(
                              'assets/images/map_main.png',
                              // rect already matches the image's aspect
                              // ratio, so `fill` here never stretches or
                              // crops it.
                              fit: BoxFit.fill,
                              color: AppColors.background.withValues(alpha: 0.1),
                              colorBlendMode: BlendMode.darken,
                            ),
                          ),
                        ),

                        // Sensor pins, positioned relative to the same
                        // fitted rect so they stay locked to their tables.
                        ..._zones.expand((zone) {
                          final event = currentEvents[zone.id];
                          if (event == null) return const <Widget>[];
                          // Dot color reflects sensor connectivity/status:
                          // black = inactive (no recent data), green = active
                          // and stable, red = active but noisy.
                          final dotColor = event.isInactive
                              ? Colors.black
                              : switch (event.severity) {
                                  _AiSeverity.low => AppColors.success,
                                  _AiSeverity.medium => AppColors.statusCritical,
                                  _AiSeverity.high => AppColors.statusCritical,
                                };
                          final left = rect.left + zone.x * rect.width;
                          final top = rect.top + zone.y * rect.height;
                          return <Widget>[
                            // Glowing GPS-style ripple pinned exactly on
                            // the table where the physical sensor sits.
                            Positioned(
                              left: left,
                              top: top,
                              child: Transform.translate(
                                offset: const Offset(-32, -32),
                                child: Tooltip(
                                  message: zone.title,
                                  child: _RipplePulse(color: dotColor),
                                ),
                              ),
                            ),
                          ];
                        }),
                      ],
                    );
                  },
                ),
              ),
            ),
            
            if (_useDemoData) 
              Positioned(
                left: 16,
                bottom: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.separator.withValues(alpha: 0.6)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.flaskConical, size: 14, color: AppColors.textSecondary),
                      SizedBox(width: 8),
                      Text(
                        'Demo stream (no Supabase)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textSecondary,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A GPS-marker-style animated beacon: a solid glowing core with two
/// concentric rings that continuously expand and fade outward, used to mark
/// the physical location of a sensor on a table.
class _RipplePulse extends StatefulWidget {
  const _RipplePulse({required this.color});

  final Color color;
  static const double _size = 64;

  @override
  State<_RipplePulse> createState() => _RipplePulseState();
}

class _RipplePulseState extends State<_RipplePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: _RipplePulse._size,
        height: _RipplePulse._size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t1 = _controller.value;
            final t2 = (_controller.value + 0.5) % 1.0;
            return Stack(
              alignment: Alignment.center,
              children: [
                _ring(t1),
                _ring(t2),
                // Soft outer glow behind the core dot.
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: 0.3),
                    boxShadow: [
                      BoxShadow(
                        color: widget.color.withValues(alpha: 0.75),
                        blurRadius: 18,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                ),
                // Solid core dot, like a GPS "you are here" marker.
                Container(
                  width: 13,
                  height: 13,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _ring(double t) {
    final maxSize = _RipplePulse._size;
    final size = 14.0 + t * (maxSize - 14.0);
    final opacity = (1 - t).clamp(0.0, 1.0);
    return Opacity(
      opacity: opacity * 0.7,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: widget.color, width: 2.5),
        ),
      ),
    );
  }
}

enum _AiSeverity { low, medium, high }

class _AiEvent {
  const _AiEvent({
    required this.x,
    required this.y,
    required this.label,
    required this.icon,
    required this.severity,
    required this.db,
    this.isInactive = false,
  });

  // Normalized 0..1 coordinates within the map area.
  final double x;
  final double y;
  final String label;
  final IconData icon;
  final _AiSeverity severity;
  final double db;
  final bool isInactive;

  static _AiEvent random(Random rng) {
    final choices = <(String, IconData, _AiSeverity, double)>[
      ('Ambient', LucideIcons.wind, _AiSeverity.low, 38 + rng.nextDouble() * 8),
      ('Conversation', LucideIcons.messageCircle, _AiSeverity.medium, 52 + rng.nextDouble() * 10),
      ('Laughing', LucideIcons.smile, _AiSeverity.medium, 55 + rng.nextDouble() * 8),
      ('Shouting', LucideIcons.megaphone, _AiSeverity.high, 68 + rng.nextDouble() * 12),
      ('Chair drag', LucideIcons.armchair, _AiSeverity.medium, 58 + rng.nextDouble() * 8),
    ];
    final c = choices[rng.nextInt(choices.length)];
    final x = rng.nextDouble().clamp(0.08, 0.92);
    final y = rng.nextDouble().clamp(0.12, 0.88);
    return _AiEvent(x: x, y: y, label: c.$1, icon: c.$2, severity: c.$3, db: c.$4);
  }
}