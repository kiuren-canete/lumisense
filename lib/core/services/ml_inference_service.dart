import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'remote_model_loader.dart';

/// One row of `sensor_readings` (what one ESP32 sent at one moment).
class SensorReading {
  const SensorReading({
    required this.id,
    required this.time,
    required this.avg,
    required this.peak,
    required this.min,
    required this.rms,
  });

  final int id;
  final DateTime time;
  final double avg;
  final double peak;
  final double min;
  final double rms;
}

class _DenseLayer {
  _DenseLayer({
    required this.weights,
    required this.bias,
    required this.activation,
  });

  /// weights[i][j] = connection from input i to output j
  final List<List<double>> weights;
  final List<double> bias;
  final String activation; // 'relu' | 'softmax'

  List<double> forward(List<double> input) {
    final out = List<double>.from(bias);
    for (int i = 0; i < input.length; i++) {
      final xi = input[i];
      final row = weights[i];
      for (int j = 0; j < out.length; j++) {
        out[j] += xi * row[j];
      }
    }
    if (activation == 'relu') {
      for (int j = 0; j < out.length; j++) {
        if (out[j] < 0) out[j] = 0;
      }
    } else if (activation == 'softmax') {
      double maxV = out[0];
      for (int j = 1; j < out.length; j++) {
        if (out[j] > maxV) maxV = out[j];
      }
      double sum = 0;
      for (int j = 0; j < out.length; j++) {
        out[j] = math.exp(out[j] - maxV);
        sum += out[j];
      }
      for (int j = 0; j < out.length; j++) {
        out[j] = out[j] / sum;
      }
    } else {
      throw FormatException('Unknown activation: $activation');
    }
    return out;
  }
}

/// The trained sound-type network, run in plain Dart (no native library).
/// Loaded from assets/models/sound_model.json, which is produced by
/// ai_training/train_sound_model.py.
///
/// It looks at a WINDOW of the last few readings of one zone and turns them
/// into 9 numbers (how loud, how spiky, how variable). [features] must stay
/// identical to window_features() in that Python script.
class SoundWindowModel {
  SoundWindowModel._({
    required this.classes,
    required this.window,
    required this.minReadings,
    required this.maxAgeSeconds,
    required this.uncertainBelow,
    required this.fallbackQuietRms,
    required this.scalerMean,
    required this.scalerScale,
    required List<_DenseLayer> layers,
  }) : _layers = layers;

  static const int featureCount = 9;

  final List<String> classes;
  final int window;
  final int minReadings;
  final int maxAgeSeconds;
  final double uncertainBelow;
  final double fallbackQuietRms;
  final List<double> scalerMean;
  final List<double> scalerScale;
  final List<_DenseLayer> _layers;

  factory SoundWindowModel.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'lumisense-mlp-v1') {
      throw FormatException('Unsupported model format: ${json['format']}');
    }

    List<double> nums(dynamic v) =>
        (v as List).map((e) => (e as num).toDouble()).toList();

    final scaler = json['scaler'] as Map<String, dynamic>;
    final layers = (json['layers'] as List).map((l) {
      final m = l as Map<String, dynamic>;
      return _DenseLayer(
        weights: (m['w'] as List).map((row) => nums(row)).toList(),
        bias: nums(m['b']),
        activation: m['activation'] as String,
      );
    }).toList();

    final model = SoundWindowModel._(
      classes: (json['classes'] as List).map((e) => e as String).toList(),
      window: (json['window'] as num).toInt(),
      minReadings: (json['min_readings'] as num).toInt(),
      maxAgeSeconds: (json['max_age_seconds'] as num).toInt(),
      uncertainBelow: (json['uncertain_below'] as num).toDouble(),
      fallbackQuietRms: (json['fallback_quiet_rms'] as num).toDouble(),
      scalerMean: nums(scaler['mean']),
      scalerScale: nums(scaler['scale']),
      layers: layers,
    );
    model._validate();
    return model;
  }

  void _validate() {
    if (scalerMean.length != featureCount || scalerScale.length != featureCount) {
      throw FormatException('Scaler does not have $featureCount values');
    }
    int width = featureCount;
    for (final layer in _layers) {
      if (layer.weights.length != width) {
        throw FormatException('Layer input size does not match');
      }
      width = layer.bias.length;
      for (final row in layer.weights) {
        if (row.length != width) {
          throw FormatException('Layer weight rows have the wrong size');
        }
      }
    }
    if (width != classes.length) {
      throw FormatException('Output size does not match class list');
    }
  }

  static double _log1p(double x) => math.log(1.0 + x);

  /// Turns a window of readings (oldest first) into the model's 9 inputs.
  List<double> features(List<SensorReading> window) {
    final n = window.length;
    double sumRms = 0;
    double maxRms = window.first.rms;
    double minRms = window.first.rms;
    double peakRatio = 0;
    double avgRatio = 0;
    int over100 = 0;
    int over1000 = 0;

    for (final r in window) {
      sumRms += r.rms;
      if (r.rms > maxRms) maxRms = r.rms;
      if (r.rms < minRms) minRms = r.rms;
      final safeRms = r.rms > 1.0 ? r.rms : 1.0;
      peakRatio += r.peak / safeRms;
      avgRatio += r.avg / safeRms;
      if (r.rms > 100) over100++;
      if (r.rms > 1000) over1000++;
    }

    final mean = sumRms / n;
    double squares = 0;
    for (final r in window) {
      final d = r.rms - mean;
      squares += d * d;
    }
    final std = math.sqrt(squares / n); // population std, like numpy

    double diffSum = 0;
    for (int i = 1; i < n; i++) {
      diffSum += (window[i].rms - window[i - 1].rms).abs();
    }
    final meanDiff = n > 1 ? diffSum / (n - 1) : 0.0;

    return [
      _log1p(mean),
      _log1p(maxRms),
      _log1p(minRms),
      _log1p(std),
      peakRatio / n,
      avgRatio / n,
      over100 / n,
      over1000 / n,
      _log1p(meanDiff),
    ];
  }

  /// Probabilities for [classes], in the same order.
  List<double> predict(List<double> features) {
    var x = List<double>.generate(
      featureCount,
      (i) => (features[i] - scalerMean[i]) / scalerScale[i],
    );
    for (final layer in _layers) {
      x = layer.forward(x);
    }
    return x;
  }
}

/// Classifies the SOUND TYPE heard by each zone (quiet / talking / clapping /
/// shouting / table_dragging / phone), using the last few readings of that zone.
///
/// Replaces the old TFLite version: it needs no native library, so it also
/// works on Windows without a DLL.
///
/// Output of [classifySound]:
///   label           top class, or 'uncertain' when the top probability is low,
///                   or 'unknown' when there are too few recent readings
///   confidence      probability of the top class
///   profile         every class with its probability, highest first
///   windowMeanRms   average rms over the readings used (also used by the
///                   source detection, which compares zones)
///   readingsUsed    how many readings were in the window
class MLInferenceService {
  MLInferenceService();

  /// For tests: skips loading and uses the given model.
  MLInferenceService.withModel(SoundWindowModel model) : _model = model;

  static const String _modelType = 'sound_type';
  static const String _assetPath = 'assets/models/sound_model.json';
  static const int _maxBuffered = 64;

  SoundWindowModel? _model;
  final Map<int, List<SensorReading>> _buffers = {};

  bool get isReady => _model != null;
  SoundWindowModel? get model => _model;

  Future<void> initialize() async {
    // 1) A model uploaded by an admin (Settings > AI Model Management)
    try {
      final remotePath = await RemoteModelLoader.fetch(_modelType);
      if (remotePath != null) {
        final text = await File(remotePath).readAsString();
        _model = SoundWindowModel.fromJson(jsonDecode(text) as Map<String, dynamic>);
        debugPrint('✓ Sound model loaded from admin upload. Classes: ${_model!.classes}');
        return;
      }
    } catch (e) {
      debugPrint('⚠ Uploaded sound model unusable, falling back to bundled: $e');
    }

    // 2) The model bundled inside the app
    try {
      final text = await rootBundle.loadString(_assetPath);
      _model = SoundWindowModel.fromJson(jsonDecode(text) as Map<String, dynamic>);
      debugPrint('✓ Sound model loaded (bundled). Classes: ${_model!.classes}');
    } catch (e) {
      debugPrint('⚠ Sound model not ready yet: $e');
    }
  }

  /// Call with the latest reading of a zone. The same reading may be passed
  /// again and again (the realtime stream repeats it) — repeats are ignored.
  Map<String, dynamic> classifySound({
    required int zoneId,
    required int readingId,
    required DateTime time,
    required double avg,
    required double peak,
    required double min,
    required double rms,
  }) {
    final model = _model;
    if (model == null) {
      return _result('unknown', 0.0, const [], rms, 0);
    }

    final buffer = _buffers.putIfAbsent(zoneId, () => <SensorReading>[]);
    final isNew = buffer.isEmpty ||
        (readingId != buffer.last.id && !time.isBefore(buffer.last.time));
    if (isNew) {
      buffer.add(SensorReading(
        id: readingId,
        time: time,
        avg: avg,
        peak: peak,
        min: min,
        rms: rms,
      ));
      if (buffer.length > _maxBuffered) buffer.removeAt(0);
    }

    final window = _recentWindow(buffer, model);
    double sum = 0;
    for (final r in window) {
      sum += r.rms;
    }
    final meanRms = sum / window.length;

    // Too few recent readings to judge the sound type.
    if (window.length < model.minReadings) {
      if (rms < model.fallbackQuietRms) {
        // The ESP32 only sends slowly when the room is quiet, so a single
        // very low reading means quiet (simple rule, not the network).
        return _result(
          'quiet',
          1.0,
          const [
            {'label': 'quiet', 'confidence': 1.0},
          ],
          meanRms,
          window.length,
        );
      }
      return _result('unknown', 0.0, const [], meanRms, window.length);
    }

    final probs = model.predict(model.features(window));
    final profile = <Map<String, dynamic>>[
      for (int i = 0; i < probs.length; i++)
        {'label': model.classes[i], 'confidence': probs[i]},
    ];
    profile.sort((a, b) =>
        (b['confidence'] as double).compareTo(a['confidence'] as double));

    final top = profile.first;
    final confidence = top['confidence'] as double;
    final label =
        confidence >= model.uncertainBelow ? top['label'] as String : 'uncertain';

    return _result(label, confidence, profile, meanRms, window.length);
  }

  /// The newest readings (at most [SoundWindowModel.window]) that are not
  /// older than maxAgeSeconds compared to the latest one.
  List<SensorReading> _recentWindow(
    List<SensorReading> buffer,
    SoundWindowModel model,
  ) {
    final latest = buffer.last.time;
    final cutoff = latest.subtract(Duration(seconds: model.maxAgeSeconds));
    final recent = buffer.where((r) => !r.time.isBefore(cutoff)).toList();
    if (recent.length > model.window) {
      return recent.sublist(recent.length - model.window);
    }
    return recent;
  }

  Map<String, dynamic> _result(
    String label,
    double confidence,
    List<Map<String, dynamic>> profile,
    double meanRms,
    int readingsUsed,
  ) {
    return {
      'label': label,
      'confidence': confidence,
      'profile': profile,
      'windowMeanRms': meanRms,
      'readingsUsed': readingsUsed,
    };
  }

  void dispose() {}
}
