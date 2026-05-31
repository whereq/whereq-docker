-- =============================================================================
-- Shared whereq cluster bootstrap
-- =============================================================================
-- Runs ONCE, only when the data directory is first initialized (empty volume).
-- It does NOT run against an already-populated cluster, so it is safe to change.
--
-- Per-database extensions (e.g. PostGIS) are enabled by each application's own
-- migrations in its own database, not here, because extensions are per-database.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- UUID generation
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- fuzzy text search
