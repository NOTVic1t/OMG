-- 006_create_package_features.sql

CREATE TABLE package_features (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  package_id    UUID NOT NULL REFERENCES packages(id),
  feature_key   TEXT NOT NULL,
  is_enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  config        JSONB NOT NULL DEFAULT '{}',
  UNIQUE (package_id, feature_key)
);

CREATE INDEX idx_pf_package_id ON package_features(package_id);
