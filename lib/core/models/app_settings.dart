
class AppSettings {
  final double noiseWarningThreshold;  
  final double noiseCriticalThreshold; 
  final double tempThreshold;         
  final String alarmPattern;          
  final double alarmDurationSec;     
  final double alarmCooldownSec;      

  const AppSettings({
    this.noiseWarningThreshold  = 60.0,
    this.noiseCriticalThreshold = 72.0,
    this.tempThreshold          = 26.0,
    this.alarmPattern           = 'short_burst',
    this.alarmDurationSec       = 5.0,
    this.alarmCooldownSec       = 30.0,
  });

  factory AppSettings.fromMap(Map<String, dynamic> map) {
    return AppSettings(
      noiseWarningThreshold:  (map['noise_warning_threshold']  as num?)?.toDouble() ?? 60.0,
      noiseCriticalThreshold: (map['noise_critical_threshold'] as num?)?.toDouble() ?? 72.0,
      tempThreshold:          (map['temp_threshold']           as num?)?.toDouble() ?? 26.0,
      alarmPattern:           (map['alarm_pattern']            as String?) ?? 'short_burst',
      alarmDurationSec:       (map['alarm_duration_sec']       as num?)?.toDouble() ?? 5.0,
      alarmCooldownSec:       (map['alarm_cooldown_sec']       as num?)?.toDouble() ?? 30.0,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': 1,
    'noise_warning_threshold':  noiseWarningThreshold,
    'noise_critical_threshold': noiseCriticalThreshold,
    'temp_threshold':           tempThreshold,
    'alarm_pattern':            alarmPattern,
    'alarm_duration_sec':       alarmDurationSec,
    'alarm_cooldown_sec':       alarmCooldownSec,
    'updated_at':               DateTime.now().toIso8601String(),
  };

  AppSettings copyWith({
    double? noiseWarningThreshold,
    double? noiseCriticalThreshold,
    double? tempThreshold,
    String? alarmPattern,
    double? alarmDurationSec,
    double? alarmCooldownSec,
  }) {
    return AppSettings(
      noiseWarningThreshold:  noiseWarningThreshold  ?? this.noiseWarningThreshold,
      noiseCriticalThreshold: noiseCriticalThreshold ?? this.noiseCriticalThreshold,
      tempThreshold:          tempThreshold          ?? this.tempThreshold,
      alarmPattern:           alarmPattern           ?? this.alarmPattern,
      alarmDurationSec:       alarmDurationSec       ?? this.alarmDurationSec,
      alarmCooldownSec:       alarmCooldownSec       ?? this.alarmCooldownSec,
    );
  }
}