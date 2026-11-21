

-- TABLE 1: SENSORS (Zones)
create table sensors (
  zone_id serial primary key,       -- Auto-incremented ID
  zone_name text not null,          -- e.g., 'IT Zone', 'CS Zone'
  status text default 'active'      -- active / not active
);

-- TABLE 2: DATA (The sensor readings)
create table data (
  id bigint generated always as identity primary key,
  zone_id int not null references sensors(zone_id), -- Foreign key linked to sensors
  sensor_data jsonb not null,       -- JSON payload containing noise_db, temp, and spectrogram array
  timestamp timestamptz default now()
);

-- Index for fast time-range queries per zone
create index idx_data_zone_time on data(zone_id, timestamp desc);

-- ============================================================
-- REALTIME: Enable live subscriptions for the Flutter app
-- ============================================================
alter publication supabase_realtime add table data;

-- ============================================================
-- SEED DATA: Register your initial departments
-- ============================================================
insert into sensors (zone_name, status) values
  ('IT Department', 'active'),
  ('CS Department', 'active'),
  ('Engineering Department', 'active');
