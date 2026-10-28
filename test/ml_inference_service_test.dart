import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumisense_monitor/core/services/ml_inference_service.dart';
import 'package:lumisense_monitor/core/services/source_inference_service.dart';

/// Run from the project root:   flutter test test/ml_inference_service_test.dart
///
/// The "golden" numbers were produced by the Python trainer
/// (ai_training/train_sound_model.py), so these tests prove the Dart code
/// computes exactly what the trained model expects.
///
/// NOTE: the golden numbers belong to the CURRENT assets/models/sound_model.json.
/// If you retrain and replace that file, regenerate the golden numbers (or the
/// 'golden window' tests will fail while everything else still works).

class _Golden {
  const _Golden({
    required this.name,
    required this.readings,
    required this.features,
    required this.probs,
    required this.label,
  });
  final String name;
  final List<List<double>> readings; // [avg, peak, min, rms]
  final List<double> features;
  final List<double> probs;
  final String label;
}

const List<_Golden> _goldens = [
    _Golden(
      name: 'quiet 8',
      readings: [
      [27.3, 89.0, 0.0, 34.1],
      [30.2, 133.0, 0.0, 38.2],
      [26.1, 104.0, 0.0, 33.1],
      [32.3, 152.0, 0.0, 41.5],
      [25.7, 99.0, 0.0, 33.0],
      [38.6, 200.0, 0.0, 49.5],
      [30.3, 123.0, 0.0, 38.1],
      [26.5, 88.0, 0.0, 32.2],
    ],
      features: [3.64968374064816, 3.9219733362813143, 3.502549875922443, 1.8684662009034698, 3.2372450473782335, 0.7918547665706559, 0.0, 0.0, 2.2572888180788695],
      probs: [1.6710506730071248e-05, 0.07473179271219567, 0.9251354118629115, 2.718726216419586e-06, 8.971578288528773e-05, 2.3650409061318244e-05],
      label: 'quiet',
    ),
    _Golden(
      name: 'shouting 8',
      readings: [
      [1020.2, 2473.0, 7.0, 1177.8],
      [880.2, 2140.0, 15.0, 1019.1],
      [869.2, 2053.0, 15.0, 1011.1],
      [898.0, 2313.0, 16.0, 1050.8],
      [849.4, 3049.0, 0.0, 1097.8],
      [903.8, 2829.0, 9.0, 1119.0],
      [913.1, 2997.0, 8.0, 1172.0],
      [886.4, 3005.0, 3.0, 1144.8],
    ],
      features: [7.00311091229889, 7.0722522508635395, 6.919782659194856, 4.138620518308019, 2.364851787301922, 0.822366655286419, 1.0, 1.0, 3.9451814239058813],
      probs: [4.308654737024959e-10, 7.79418121747815e-17, 2.186894878528959e-22, 0.9999999995691344, 2.1761096769521493e-26, 6.327698713173868e-20],
      label: 'shouting',
    ),
    _Golden(
      name: 'talking 8',
      readings: [
      [17.6, 59.0, 0.0, 21.9],
      [31.8, 109.0, 0.0, 39.6],
      [47.0, 192.0, 0.0, 57.5],
      [157.4, 468.0, 1.0, 186.1],
      [55.3, 227.0, 0.0, 69.8],
      [14.0, 56.0, 0.0, 17.6],
      [118.5, 399.0, 0.0, 149.0],
      [17.3, 69.0, 0.0, 22.5],
    ],
      features: [4.269697449699962, 5.231643233280044, 2.9231615807191558, 4.0990236843530115, 2.9348728513091684, 0.8027206839022192, 0.25, 0.0, 4.447011484763294],
      probs: [0.1198566605877937, 0.013207253562066493, 4.582052708367113e-08, 2.538857965105156e-06, 0.0019564032195036538, 0.8649770979521438],
      label: 'talking',
    ),
    _Golden(
      name: 'clapping 5',
      readings: [
      [1190.0, 8384.0, 9.0, 1637.5],
      [68.8, 256.0, 0.0, 87.1],
      [299.8, 1112.0, 3.0, 376.6],
      [83.8, 313.0, 0.0, 104.7],
      [335.3, 1141.0, 4.0, 413.3],
    ],
      features: [6.263093454237515, 7.401536468138869, 4.478472532942134, 6.352298632727883, 3.352417139911418, 0.7848682950828667, 0.8, 0.2, 6.40704498895724],
      probs: [0.9998812557181538, 1.975637836319076e-06, 7.672127163995596e-18, 2.7267204699656126e-05, 8.950143747217953e-05, 1.838167465157921e-12],
      label: 'clapping',
    ),
    _Golden(
      name: 'dragging 8',
      readings: [
      [100.6, 641.0, 0.0, 145.7],
      [106.9, 344.0, 0.0, 131.5],
      [282.2, 1064.0, 4.0, 350.2],
      [100.6, 300.0, 0.0, 121.9],
      [519.9, 2304.0, 0.0, 673.3],
      [46.6, 211.0, 0.0, 58.8],
      [68.9, 336.0, 0.0, 90.2],
      [52.9, 203.0, 0.0, 66.9],
    ],
      features: [5.326965560136583, 6.513675115740536, 4.091005660956586, 5.2872486622291, 3.285567506387554, 0.7817192419641377, 0.625, 0.0, 5.485863347478798],
      probs: [0.08446038840447549, 0.767535077177995, 2.1548294842514825e-12, 5.257769798604223e-06, 0.1479989879170729, 2.887285030687675e-07],
      label: 'phone',
    ),
];

List<SensorReading> _asReadings(
  List<List<double>> rows, {
  int firstId = 1,
  int startSecond = 0,
}) {
  final start = DateTime.utc(2026, 1, 1, 0, 0, 0);
  return [
    for (int i = 0; i < rows.length; i++)
      SensorReading(
        id: firstId + i,
        time: start.add(Duration(seconds: startSecond + i)),
        avg: rows[i][0],
        peak: rows[i][1],
        min: rows[i][2],
        rms: rows[i][3],
      ),
  ];
}

Map<String, dynamic> _feed(MLInferenceService svc, SensorReading r, {int zone = 1}) {
  return svc.classifySound(
    zoneId: zone,
    readingId: r.id,
    time: r.time,
    avg: r.avg,
    peak: r.peak,
    min: r.min,
    rms: r.rms,
  );
}

void main() {
  late SoundWindowModel model;

  setUpAll(() {
    final text = File('assets/models/sound_model.json').readAsStringSync();
    model = SoundWindowModel.fromJson(jsonDecode(text) as Map<String, dynamic>);
  });

  group('SoundWindowModel matches the Python reference', () {
    test('model file has 6 classes and 9 inputs', () {
      expect(model.classes.length, 6);
      expect(model.classes, contains('shouting'));
      expect(SoundWindowModel.featureCount, 9);
    });

    for (final g in _goldens) {
      test('golden window: ${g.name}', () {
        final window = _asReadings(g.readings);
        final f = model.features(window);
        expect(f.length, g.features.length);
        for (int i = 0; i < f.length; i++) {
          expect(f[i], closeTo(g.features[i], 1e-6), reason: 'feature $i');
        }
        final p = model.predict(f);
        expect(p.length, g.probs.length);
        for (int i = 0; i < p.length; i++) {
          expect(p[i], closeTo(g.probs[i], 1e-5), reason: 'probability $i');
        }
        expect(p.reduce((a, b) => a + b), closeTo(1.0, 1e-9));
      });
    }
  });

  group('MLInferenceService', () {
    test('without a model it answers unknown', () {
      final svc = MLInferenceService();
      final r = svc.classifySound(
        zoneId: 1, readingId: 1, time: DateTime.utc(2026), avg: 5, peak: 9, min: 0, rms: 6,
      );
      expect(r['label'], 'unknown');
    });

    test('one very low reading counts as quiet', () {
      final svc = MLInferenceService.withModel(model);
      final r = _feed(svc, _asReadings([[5.0, 16.0, 0.0, 6.0]]).first);
      expect(r['label'], 'quiet');
      expect(r['readingsUsed'], 1);
    });

    test('one loud reading is unknown until 4 readings exist', () {
      final svc = MLInferenceService.withModel(model);
      final rows = _asReadings([
        [900.0, 3000.0, 0.0, 1200.0],
        [900.0, 3000.0, 0.0, 1200.0],
        [900.0, 3000.0, 0.0, 1200.0],
      ]);
      Map<String, dynamic> r = {};
      for (final x in rows) {
        r = _feed(svc, x);
        expect(r['label'], 'unknown');
      }
      expect(r['readingsUsed'], 3);
    });

    test('the same reading sent again is ignored', () {
      final svc = MLInferenceService.withModel(model);
      final one = _asReadings([[500.0, 900.0, 0.0, 600.0]]).first;
      _feed(svc, one);
      _feed(svc, one);
      final r = _feed(svc, one);
      expect(r['readingsUsed'], 1);
    });

    test('8 shouting readings are classified as shouting', () {
      final svc = MLInferenceService.withModel(model);
      final rows = _asReadings(
[
      [1020.2, 2473.0, 7.0, 1177.8],
      [880.2, 2140.0, 15.0, 1019.1],
      [869.2, 2053.0, 15.0, 1011.1],
      [898.0, 2313.0, 16.0, 1050.8],
      [849.4, 3049.0, 0.0, 1097.8],
      [903.8, 2829.0, 9.0, 1119.0],
      [913.1, 2997.0, 8.0, 1172.0],
      [886.4, 3005.0, 3.0, 1144.8],
    ]);
      Map<String, dynamic> r = {};
      for (final x in rows) {
        r = _feed(svc, x);
      }
      expect(r['readingsUsed'], 8);
      expect(r['label'], 'shouting');
      expect(r['confidence'] as double, greaterThan(0.9));
      final profile = r['profile'] as List;
      expect(profile.length, 6);
      expect((profile.first as Map)['label'], 'shouting');
    });

    test('readings older than 15 seconds leave the window', () {
      final svc = MLInferenceService.withModel(model);
      final old = _asReadings([
        [40.0, 100.0, 0.0, 50.0],
        [40.0, 100.0, 0.0, 50.0],
        [40.0, 100.0, 0.0, 50.0],
        [40.0, 100.0, 0.0, 50.0],
      ]);
      for (final x in old) {
        _feed(svc, x);
      }
      final lateReading = _asReadings([[400.0, 900.0, 0.0, 500.0]], firstId: 100, startSecond: 100).first;
      final r = _feed(svc, lateReading);
      expect(r['readingsUsed'], 1);
      expect(r['label'], 'unknown');
    });

    test('zones keep separate windows', () {
      final svc = MLInferenceService.withModel(model);
      final a = _asReadings([[400.0, 900.0, 0.0, 500.0]]).first;
      _feed(svc, a, zone: 1);
      final r = _feed(svc, a, zone: 2);
      expect(r['readingsUsed'], 1);
    });
  });

  group('SourceInferenceService', () {
    final src = SourceInferenceService();

    test('the loudest zone is the source', () {
      final r = src.classifySource(
        windowRms: {1: 300.0, 2: 100.0, 3: 90.0},
        soundLabels: {1: 'talking', 2: 'quiet', 3: 'quiet'},
      );
      expect(r['noiseDetected'], true);
      expect(r['likelySource'], 'IT Department');
      expect(r['confidence'] as double, closeTo(0.75, 1e-9));
    });

    test('zone 2 and 3 use the CS / Engineering labels', () {
      final r2 = src.classifySource(
        windowRms: {1: 50.0, 2: 400.0, 3: 60.0},
        soundLabels: {1: 'quiet', 2: 'clapping', 3: 'quiet'},
      );
      expect(r2['likelySource'], 'CS Department');
      final r3 = src.classifySource(
        windowRms: {1: 50.0, 2: 60.0, 3: 900.0},
        soundLabels: {1: 'quiet', 2: 'quiet', 3: 'shouting'},
      );
      expect(r3['likelySource'], 'Engineering Department');
    });

    test('no noise when the loudest zone sounds quiet', () {
      final r = src.classifySource(
        windowRms: {1: 30.0, 2: 25.0, 3: 20.0},
        soundLabels: {1: 'quiet', 2: 'quiet', 3: 'quiet'},
      );
      expect(r['noiseDetected'], false);
      expect(r['likelySource'], isNull);
    });

    test('needs at least two zones', () {
      final r = src.classifySource(
        windowRms: {1: 300.0},
        soundLabels: {1: 'talking'},
      );
      expect(r['noiseDetected'], false);
      expect(r['confidence'], 0.0);
    });
  });
}
