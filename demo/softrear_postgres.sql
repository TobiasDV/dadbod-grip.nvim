-- Optional Softrear schema lab. Run only in your disposable local PostgreSQL DB.
-- Creates a fresh grip_demo schema; an existing name is intentionally rejected.
-- No roles, extensions, grants, or server settings are changed.
BEGIN;
CREATE SCHEMA grip_demo;

CREATE TABLE grip_demo.incidents (
  id integer,
  incident_date date,
  roll_sku text NOT NULL,
  severity integer NOT NULL CHECK (severity BETWEEN 1 AND 10),
  resolved boolean NOT NULL DEFAULT false,
  PRIMARY KEY (id, incident_date)
) PARTITION BY RANGE (incident_date);

CREATE TABLE grip_demo.incidents_2026 PARTITION OF grip_demo.incidents
  FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')
  PARTITION BY RANGE (incident_date);
CREATE TABLE grip_demo.incidents_2026_01 PARTITION OF grip_demo.incidents_2026
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE grip_demo.incidents_2026_later PARTITION OF grip_demo.incidents_2026
  FOR VALUES FROM ('2026-02-01') TO ('2027-01-01');
CREATE TABLE grip_demo.incidents_default PARTITION OF grip_demo.incidents DEFAULT;

INSERT INTO grip_demo.incidents VALUES
  (1, '2026-01-10', 'ULTRA_BUDGET_XTRM', 9, false),
  (2, '2026-01-20', 'COMFORT_CLASSIC_2PLY', 10, true),
  (3, '2026-03-03', 'TITANIUM_TRIPLE_PLY', 7, false),
  (4, '2027-01-01', 'CLOUD_TOUCH_4PLY', 2, true);

CREATE FUNCTION grip_demo.severity_label(value integer) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN value IS NULL THEN 'unrated'
              WHEN value >= 8 THEN 'high'
              WHEN value >= 5 THEN 'medium'
              ELSE 'low' END
$$;

CREATE VIEW grip_demo.open_incidents AS
SELECT id, incident_date, roll_sku, severity,
       grip_demo.severity_label(severity) AS priority
FROM grip_demo.incidents
WHERE NOT resolved;
COMMIT;
