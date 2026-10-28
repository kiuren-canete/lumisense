import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'remote_model_loader.dart';

/// Service that runs the trained ANN model(s) to classify sounds.
///
/// Runs TWO models per reading:
///   1. PRIMARY (reliable): quiet / normal_activity / disruptive — 72.6%
///      test accuracy. This is what drives the "Live Sound Profile" bars
///      and any threshold/alerting logic. Supports admin upload via
///      RemoteModelLoader (see Settings > AI Model Management).
///   2. SECONDARY (best guess): the original 11 fine-grained types
///      (clapping, furniture_dragging, shouting, etc.) — only ~34% test
///      accuracy, since 4 loudness-only sensor numbers can't reliably
///      separate that many similar sounds. Shown as a low-confidence
///      "best guess" label alongside the reliable tier, never as the
///      primary signal. Bundled-only for now (not swappable via upload).
///
/// Input (both models): 4 numbers from the INMP441 sensor (Avg, Peak, Min, RMS)
class MLInferenceService {
  Interpreter? _interpreter;
  List<String> _labels = [];
  List<double> _scalerMean = [];
  List<double> _scalerScale = [];

  Interpreter? _fineInterpreter;
  List<String> _fineLabels = [];
  List<double> _fineScalerMean = [];
  List<double> _fineScalerScale = [];

  static const String _modelType = 'sound_type';

  Future<void> initialize() async {
    await _initializePrimary();
    await _initializeFineGrained();
  }

  Future<void> _initializePrimary() async {
    try {
      final remote = await RemoteModelLoader.fetch(_modelType);
      if (remote != null) {
        _interpreter = Interpreter.fromFile(File(remote['tflite']!));
        _labels = (await File(remote['labels']!).readAsString())
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
        final scale = _parseScaler(await File(remote['scaler']!).readAsString());
        _scalerMean = scale.$1;
        _scalerScale = scale.$2;
        debugPrint('✓ ML model loaded from admin upload. Labels: $_labels');
        return;
      }
    } catch (e) {
      debugPrint('⚠ Remote ML model failed, falling back to bundled: $e');
    }

    try {
      _interpreter = await Interpreter.fromAsset('assets/models/sound_classifier.tflite');
      final labelData = await rootBundle.loadString('assets/models/class_labels.txt');
      _labels = labelData.split('\n').where((l) => l.isNotEmpty).toList();
      final scalerData = await rootBundle.loadString('assets/models/scaler_params.txt');
      final scale = _parseScaler(scalerData);
      _scalerMean = scale.$1;
      _scalerScale = scale.$2;
      debugPrint('✓ ML model loaded (bundled). Labels: $_labels');
    } catch (e) {
      debugPrint('⚠ ML model not ready yet: $e');
    }
  }

  Future<void> _initializeFineGrained() async {
    try {
      _fineInterpreter =
          await Interpreter.fromAsset('assets/models/sound_classifier_finegrained.tflite');
      final labelData =
          await rootBundle.loadString('assets/models/class_labels_finegrained.txt');
      _fineLabels = labelData.split('\n').where((l) => l.isNotEmpty).toList();
      final scalerData =
          await rootBundle.loadString('assets/models/scaler_params_finegrained.txt');
      final scale = _parseScaler(scalerData);
      _fineScalerMean = scale.$1;
      _fineScalerScale = scale.$2;
      debugPrint('✓ Fine-grained ML model loaded (bundled). Labels: $_fineLabels');
    } catch (e) {
      debugPrint('⚠ Fine-grained ML model not ready yet: $e');
    }
  }

  (List<double>, List<double>) _parseScaler(String scalerData) {
    List<double> mean = [];
    List<double> scale = [];
    for (final line in scalerData.split('\n')) {
      if (line.startsWith('mean:')) {
        mean = line.replaceFirst('mean:', '').split(',').map(double.parse).toList();
      } else if (line.startsWith('scale:')) {
        scale = line.replaceFirst('scale:', '').split(',').map(double.parse).toList();
      }
    }
    return (mean, scale);
  }

  /// Takes the raw sensor data and returns the predicted sound class from
  /// the PRIMARY (reliable) model, plus a full confidence profile across
  /// its classes for the "Live Sound Profile" UI.
  Map<String, dynamic> classifySound({
    required double avg,
    required double peak,
    required double min,
    required double rms,
  }) {
    if (_interpreter == null || _labels.isEmpty || _scalerMean.isEmpty) {
      return {'label': 'unknown', 'confidence': 0.0, 'profile': []};
    }

    try {
      final normalized = [
        (avg - _scalerMean[0]) / _scalerScale[0],
        (peak - _scalerMean[1]) / _scalerScale[1],
        (min - _scalerMean[2]) / _scalerScale[2],
        (rms - _scalerMean[3]) / _scalerScale[3],
      ];

      var input = [normalized];
      var output = List.filled(1 * _labels.length, 0.0).reshape([1, _labels.length]);
      _interpreter!.run(input, output);

      List<double> probabilities = (output[0] as List).cast<double>();
      int maxIndex = 0;
      double maxProb = probabilities[0];
      for (int i = 1; i < probabilities.length; i++) {
        if (probabilities[i] > maxProb) {
          maxProb = probabilities[i];
          maxIndex = i;
        }
      }

      List<Map<String, dynamic>> fullProfile = [];
      for (int i = 0; i < probabilities.length; i++) {
        fullProfile.add({'label': _labels[i], 'confidence': probabilities[i]});
      }
      fullProfile.sort((a, b) => (b['confidence'] as double).compareTo(a['confidence'] as double));

      return {
        'label': _labels[maxIndex],
        'confidence': maxProb,
        'profile': fullProfile,
      };
    } catch (e) {
      return {'label': 'error', 'confidence': 0.0, 'profile': []};
    }
  }

  /// Secondary "best guess" — the fine-grained 11-type prediction (e.g.
  /// "clapping", "furniture_dragging"). Only ~34% test accuracy, so this
  /// should always be displayed as a low-confidence hint, never as fact.
  /// Returns only the top label + confidence (no full profile needed).
  Map<String, dynamic> classifySoundFineGrained({
    required double avg,
    required double peak,
    required double min,
    required double rms,
  }) {
    if (_fineInterpreter == null || _fineLabels.isEmpty || _fineScalerMean.isEmpty) {
      return {'label': null, 'confidence': 0.0};
    }

    try {
      final normalized = [
        (avg - _fineScalerMean[0]) / _fineScalerScale[0],
        (peak - _fineScalerMean[1]) / _fineScalerScale[1],
        (min - _fineScalerMean[2]) / _fineScalerScale[2],
        (rms - _fineScalerMean[3]) / _fineScalerScale[3],
      ];

      var input = [normalized];
      var output =
          List.filled(1 * _fineLabels.length, 0.0).reshape([1, _fineLabels.length]);
      _fineInterpreter!.run(input, output);

      List<double> probabilities = (output[0] as List).cast<double>();
      int maxIndex = 0;
      double maxProb = probabilities[0];
      for (int i = 1; i < probabilities.length; i++) {
        if (probabilities[i] > maxProb) {
          maxProb = probabilities[i];
          maxIndex = i;
        }
      }

      return {'label': _fineLabels[maxIndex], 'confidence': maxProb};
    } catch (e) {
      return {'label': null, 'confidence': 0.0};
    }
  }

  void dispose() {
    _interpreter?.close();
    _fineInterpreter?.close();
  }
}