import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ZoneBucket {
  const ZoneBucket({
    required this.minuteOfDay,
    required this.avgRms,
    required this.avgTemp,
  });

  final int minuteOfDay;
  final double avgRms;
  final double avgTemp;
}

class _Acc {
  double rms = 0;
  double temp = 0;
  int n = 0;
}


Future<List<ZoneBucket>> fetchZoneBuckets(
  SupabaseClient client, {
  required int zoneId,
  required DateTime from,
  required DateTime to,
  required int bucketMinutes,
  required int firstHour,
  required int endHour,
}) async {

  final fromUtc = from.toUtc().toIso8601String();
  final toUtc = to.toUtc().toIso8601String();
  final bucketSeconds = bucketMinutes * 60;
  final acc = <int, _Acc>{};
  var source = 'rpc';

  try {
    final res = await client.rpc('zone_buckets', params: {
      'p_zone': zoneId,
      'p_from': fromUtc,
      'p_to': toUtc,
      'p_bucket_seconds': bucketSeconds,
    });
    for (final r in (res as List)) {
      final m = r as Map<String, dynamic>;
      final a = _Acc()
        ..rms = (m['avg_rms'] as num?)?.toDouble() ?? 0
        ..temp = (m['avg_temp'] as num?)?.toDouble() ?? 0
        ..n = 1;
      acc[(m['bucket_epoch'] as num).toInt()] = a;
    }
  } catch (e) {
    debugPrint('[zone_buckets] zone $zoneId: server function unavailable '
        '($e) -> reading rows instead. Run '
        'SqlDataMigration/add_zone_buckets_function.sql in Supabase.');
    source = 'rows';
    acc.clear();
    const page = 1000;
    for (var offset = 0; offset < 60000; offset += page) {
      final chunk = await client
          .from('sensor_readings')
          .select('rms, temperature_c, created_at')
          .eq('zone_id', zoneId)
          .gte('created_at', fromUtc)
          .lte('created_at', toUtc)
          .order('created_at', ascending: true)
          .range(offset, offset + page - 1);
      for (final row in chunk) {
        final ts = DateTime.parse(row['created_at'] as String);
        final epoch = ts.millisecondsSinceEpoch ~/ 1000;
        final key = (epoch ~/ bucketSeconds) * bucketSeconds;
        final a = acc.putIfAbsent(key, () => _Acc());
        a.rms += (row['rms'] as num?)?.toDouble() ?? 0;
        a.temp += (row['temperature_c'] as num?)?.toDouble() ?? 0;
        a.n++;
      }
      if (chunk.length < page) break;
    }
  }

  final out = <ZoneBucket>[];
  for (final entry in acc.entries) {
    final local = DateTime.fromMillisecondsSinceEpoch(
      entry.key * 1000,
      isUtc: true,
    ).toLocal();
    if (local.hour < firstHour || local.hour >= endHour) continue;
    final a = entry.value;
    out.add(ZoneBucket(
      minuteOfDay: local.hour * 60 + local.minute,
      avgRms: a.n > 0 ? a.rms / a.n : 0,
      avgTemp: a.n > 0 ? a.temp / a.n : 0,
    ));
  }
  out.sort((x, y) => x.minuteOfDay.compareTo(y.minuteOfDay));

  debugPrint('[zone_buckets] zone $zoneId via $source: '
      '$fromUtc .. $toUtc, ${bucketMinutes}min buckets -> ${out.length} points');
  return out;
}
