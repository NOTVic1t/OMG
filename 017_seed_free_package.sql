-- 017_seed_free_package.sql

INSERT INTO packages (
  name, slug, price_monthly, price_yearly, currency,
  max_invitations, max_guests, max_photos,
  is_active, is_reseller, sort_order
) VALUES (
  'Free', 'free', 0, 0, 'IDR',
  1, 50, 5,
  TRUE, FALSE, 0
);

INSERT INTO package_features (package_id, feature_key, is_enabled)
SELECT p.id, f.feature_key, f.is_enabled
FROM packages p
CROSS JOIN (VALUES
  ('countdown_timer',       TRUE),
  ('rsvp_open',             TRUE),
  ('music_player',          FALSE),
  ('gift_registry',         FALSE),
  ('custom_domain',         FALSE),
  ('guest_import_csv',      FALSE),
  ('export_rsvp_csv',       FALSE),
  ('analytics_basic',       FALSE),
  ('analytics_advanced',    FALSE),
  ('remove_platform_badge', FALSE),
  ('premium_themes',        FALSE),
  ('team_members',          FALSE)
) AS f(feature_key, is_enabled)
WHERE p.slug = 'free';
