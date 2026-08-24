-- A site is one reef scan produced by the local Metashape + CoralScapes
-- pipeline. Its metadata lives here; its artifacts live in site_assets and the
-- content-addressed blob store on disk.

CREATE TABLE sites (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text NOT NULL,
    priority      text NOT NULL DEFAULT 'medium'
                    CHECK (priority IN ('high', 'medium', 'low')),
    -- Mirrors UploadedSite.State on the clients. A site is created as
    -- 'importing' and the local pipeline patches it to a terminal state.
    state         text NOT NULL DEFAULT 'importing'
                    CHECK (state IN ('importing', 'processing', 'ready',
                                     'failed', 'cancelled', 'interrupted')),
    state_message text,
    photo_count   integer NOT NULL DEFAULT 0 CHECK (photo_count >= 0),
    tags          text[] NOT NULL DEFAULT '{}',
    -- Site-relative path of the cover image, resolved through site_assets.
    cover_path    text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX sites_state_idx ON sites (state);

-- One row per artifact file. rel_path is spelled exactly as the manifest spells
-- it, because that is the string the clients build URLs from.
CREATE TABLE site_assets (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    site_id      uuid NOT NULL REFERENCES sites (id) ON DELETE CASCADE,
    rel_path     text NOT NULL,
    -- "<sha256 hex><ext>"; the blob lives at data/blobs/<2>/<2>/<key>.
    storage_key  text NOT NULL,
    content_type text NOT NULL,
    bytes        bigint NOT NULL CHECK (bytes >= 0),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (site_id, rel_path)
);

-- Used to decide whether a blob is still referenced before unlinking it.
CREATE INDEX site_assets_storage_key_idx ON site_assets (storage_key);

-- The AnalysisSequence manifest, stored verbatim. It is the local pipeline's
-- contract with the viewers, not this service's; keeping it opaque means a
-- pipeline change does not need a migration here.
CREATE TABLE site_analyses (
    site_id        uuid PRIMARY KEY REFERENCES sites (id) ON DELETE CASCADE,
    manifest       jsonb NOT NULL,
    generated_at   timestamptz,
    semantic_model text,
    depth_producer text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
