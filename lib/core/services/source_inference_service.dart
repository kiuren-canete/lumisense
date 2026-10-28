import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'remote_model_loader.dart';

/// Runs the fused 3-sensor "where is this noise actually coming from"
/// model, trained on real simultaneous readings from all 3 zone sensors
/// (see ai_training/train_source_classifier.py).
///
/// Input:  12 numbers — the CURRENT reading from all 3 zones at once:
///   [cs_avg, cs_peak, cs_min, cs_rms,
///    eng_avg, eng_peak, eng_min, eng_rms,
///    it_avg, it_peak, it_min, it_rms]
/// Output: { noiseDetected, likelySource, confidence }
///
/// Unlike [MLInferenceService] (which classifies each zone's sound type in
/// isolation), this model needs a snapshot of all 3 zones at the same
/// moment — sound leaks between rooms, so comparing sensors against each
/// other is what actually identifies the true source.
class SourceInferenceService {
  Interpreter? _interpreter;
  List<String> _labels = [];
  List<double> _scalerMean = [];
  List<double> _scalerScale = [];

  static const String _modelType = 'noise_source';

  Future<void> initialize() async {
    try {
      final remote = await RemoteModelLoader.fetch(_modelType);
      if (remote != null) {
        _interpreter = Interpreter.fromFile(File(remote['tflite']!));
        _labels = (await File(remote['labels']!).readAsString())
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
        _loadScaler(await File(remote['scaler']!).readAsString());
        debugPrint('✓ Source model loaded from admin upload. Labels: $_labels');
        return;
      }
    } catch (e) {
      debugPrint('⚠ Remote source model failed, falling back to bundled: $e');
    }

    try {
      _interpreter = await Interpreter.fromAsset('assets/models/source_classifier.tflite');
      _labels = (await rootBundle.loadString('assets/models/source_class_labels.txt'))
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      _loadScaler(await rootBundle.loadString('assets/models/source_scaler_params.txt'));
      debugPrint('✓ Source model loaded (bundled). Labels: $_labels');
    } catch (e) {
      debugPrint('⚠ Source model not ready yet: $e');
    }
  }

  void _loadScaler(String scalerData) {
    for (final line in scalerData.split('\n')) {
      if (line.startsWith('mean:')) {
        _scalerMean = line.replaceFirst('mean:', '').split(',').map(double.parse).toList();
      } else if (line.startsWith('scale:')) {
        _scalerScale = line.replaceFirst('scale:', '').split(',').map(double.parse).toList();
      }
    }
  }

  /// [cs], [eng], [it] must each contain the keys 'avg', 'peak', 'min',
  /// 'rms' — the latest reading from that zone's sensor, all captured at
  /// (approximately) the same moment.
  Map<String, dynamic> classifySource({
    required Map<String, double> cs,
    required Map<String, double> eng,
    required Map<String, double> it,
  }) {
    if (_interpreter == null || _labels.isEmpty || _scalerMean.isEmpty) {
      return {'noiseDetected': false, 'likelySource': null, 'confidence': 0.0};
    }

    try {
      final raw = [
        cs['avg']!, cs['peak']!, cs['min']!, cs['rms']!,
        eng['avg']!, eng['peak']!, eng['min']!, eng['rms']!,
        it['avg']!, it['peak']!, it['min']!, it['rms']!,
      ];
      final normalized = List.generate(
        raw.length,
        (i) => (raw[i] - _scalerMean[i]) / _scalerScale[i],
      );

      var input = [normalized];
      var output = List.filled(1 * _labels.length, 0.0).reshape([1, _labels.length]);
      _interpreter!.run(input, output);

      final probs = (output[0] as List).cast<double>();
      int maxIndex = 0;
      double maxProb = probs[0];
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > maxProb) {
          maxProb = probs[i];
          maxIndex = i;
        }
      }

      final predicted = _labels[maxIndex];
      final isNoise = predicted != 'none';

      return {
        'noiseDetected': isNoise,
        'likelySource': isNoise ? predicted : null,
        'confidence': maxProb,
      };
    } catch (e) {
      return {'noiseDetected': false, 'likelySource': null, 'confidence': 0.0};
    }
  }

  void dispose() => _interpreter?.close();
}
