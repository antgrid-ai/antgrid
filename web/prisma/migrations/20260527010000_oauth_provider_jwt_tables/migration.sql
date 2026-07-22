-- Better-Auth JWT plugin: JWKS key store
CREATE TABLE "jwks" (
  "id"          TEXT NOT NULL,
  "public_key"  TEXT NOT NULL,
  "private_key" TEXT NOT NULL,
  "created_at"  TIMESTAMPTZ(6) NOT NULL,
  "expires_at"  TIMESTAMPTZ(6),

  CONSTRAINT "jwks_pkey" PRIMARY KEY ("id")
);

-- Better-Auth OAuth Provider plugin: OAuth clients
CREATE TABLE "oauth_client" (
  "id"                          TEXT NOT NULL,
  "client_id"                   TEXT NOT NULL,
  "client_secret"               TEXT,
  "disabled"                    BOOLEAN DEFAULT false,
  "skip_consent"                BOOLEAN,
  "enable_end_session"          BOOLEAN,
  "subject_type"                TEXT,
  "scopes"                      TEXT[],
  "user_id"                     TEXT,
  "created_at"                  TIMESTAMPTZ(6),
  "updated_at"                  TIMESTAMPTZ(6),
  "name"                        TEXT,
  "uri"                         TEXT,
  "icon"                        TEXT,
  "contacts"                    TEXT[],
  "tos"                         TEXT,
  "policy"                      TEXT,
  "software_id"                 TEXT,
  "software_version"            TEXT,
  "software_statement"          TEXT,
  "redirect_uris"               TEXT[],
  "post_logout_redirect_uris"   TEXT[],
  "token_endpoint_auth_method"  TEXT,
  "grant_types"                 TEXT[],
  "response_types"              TEXT[],
  "public"                      BOOLEAN,
  "type"                        TEXT,
  "require_pkce"                BOOLEAN,
  "reference_id"                TEXT,
  "metadata"                    JSONB,

  CONSTRAINT "oauth_client_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "oauth_client_client_id_key" ON "oauth_client"("client_id");
CREATE INDEX "oauth_client_user_id_idx" ON "oauth_client"("user_id");

-- Better-Auth OAuth Provider plugin: Access tokens (opaque store when JWT plugin active)
CREATE TABLE "oauth_access_token" (
  "id"           TEXT NOT NULL,
  "token"        TEXT NOT NULL,
  "client_id"    TEXT NOT NULL,
  "session_id"   TEXT,
  "user_id"      TEXT,
  "reference_id" TEXT,
  "refresh_id"   TEXT,
  "expires_at"   TIMESTAMPTZ(6) NOT NULL,
  "created_at"   TIMESTAMPTZ(6) NOT NULL,
  "scopes"       TEXT[],

  CONSTRAINT "oauth_access_token_pkey" PRIMARY KEY ("id"),
  CONSTRAINT "oauth_access_token_client_id_fkey" FOREIGN KEY ("client_id")
    REFERENCES "oauth_client"("client_id") ON DELETE CASCADE
);

CREATE UNIQUE INDEX "oauth_access_token_token_key" ON "oauth_access_token"("token");
CREATE INDEX "oauth_access_token_client_id_idx" ON "oauth_access_token"("client_id");
CREATE INDEX "oauth_access_token_session_id_idx" ON "oauth_access_token"("session_id");
CREATE INDEX "oauth_access_token_user_id_idx" ON "oauth_access_token"("user_id");
CREATE INDEX "oauth_access_token_refresh_id_idx" ON "oauth_access_token"("refresh_id");

-- Better-Auth OAuth Provider plugin: Refresh tokens
CREATE TABLE "oauth_refresh_token" (
  "id"           TEXT NOT NULL,
  "token"        TEXT NOT NULL,
  "client_id"    TEXT NOT NULL,
  "session_id"   TEXT,
  "user_id"      TEXT NOT NULL,
  "reference_id" TEXT,
  "expires_at"   TIMESTAMPTZ(6) NOT NULL,
  "created_at"   TIMESTAMPTZ(6) NOT NULL,
  "revoked"      TIMESTAMPTZ(6),
  "auth_time"    TIMESTAMPTZ(6),
  "scopes"       TEXT[],

  CONSTRAINT "oauth_refresh_token_pkey" PRIMARY KEY ("id"),
  CONSTRAINT "oauth_refresh_token_client_id_fkey" FOREIGN KEY ("client_id")
    REFERENCES "oauth_client"("client_id") ON DELETE CASCADE
);

CREATE UNIQUE INDEX "oauth_refresh_token_token_key" ON "oauth_refresh_token"("token");
CREATE INDEX "oauth_refresh_token_client_id_idx" ON "oauth_refresh_token"("client_id");
CREATE INDEX "oauth_refresh_token_session_id_idx" ON "oauth_refresh_token"("session_id");
CREATE INDEX "oauth_refresh_token_user_id_idx" ON "oauth_refresh_token"("user_id");

-- Better-Auth OAuth Provider plugin: Consent records
CREATE TABLE "oauth_consent" (
  "id"           TEXT NOT NULL,
  "client_id"    TEXT NOT NULL,
  "user_id"      TEXT,
  "reference_id" TEXT,
  "scopes"       TEXT[],
  "created_at"   TIMESTAMPTZ(6) NOT NULL,
  "updated_at"   TIMESTAMPTZ(6) NOT NULL,

  CONSTRAINT "oauth_consent_pkey" PRIMARY KEY ("id"),
  CONSTRAINT "oauth_consent_client_id_fkey" FOREIGN KEY ("client_id")
    REFERENCES "oauth_client"("client_id") ON DELETE CASCADE
);

CREATE INDEX "oauth_consent_client_id_idx" ON "oauth_consent"("client_id");
CREATE INDEX "oauth_consent_user_id_idx" ON "oauth_consent"("user_id");
