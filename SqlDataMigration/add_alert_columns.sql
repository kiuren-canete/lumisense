
alter table public.sensor_readings
  add column if not exists alert_level text    not null default 'quiet',
  add column if not exists buzzer_on   boolean not null default false;

alter table public.sensor_readings
  drop constraint if exists sensor_readings_alert_level_check;

alter table public.sensor_readings
  add constraint sensor_readings_alert_level_check
  check (alert_level in ('quiet', 'normal', 'warning', 'critical'));

comment on column public.sensor_readings.alert_level is
  'Level decided by the ESP32 itself: quiet | normal | warning (blue LED) | critical (red LED + buzzer)';
comment on column public.sensor_readings.buzzer_on is
  'true if the ESP32 buzzer was sounding when this reading was sent';

-- Verify (read-only): both columns should be listed
select column_name, data_type, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'sensor_readings'
order by ordinal_position;
