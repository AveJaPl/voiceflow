CREATE TABLE IF NOT EXISTS devices (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  token_hash  TEXT NOT NULL,
  platform    TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS devices_token_idx ON devices(token_hash);

CREATE TABLE IF NOT EXISTS rooms (
  id          BIGSERIAL PRIMARY KEY,
  code        TEXT NOT NULL UNIQUE,
  name        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS room_members (
  room_id     BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, device_id)
);

-- Sesja to mierzony odcinek pracy w pokoju. Pierwsza powstaje razem z pokojem:
-- nikt nie tworzy pokoju, żeby siedzieć w nim sam.
CREATE TABLE IF NOT EXISTS sessions (
  id          BIGSERIAL PRIMARY KEY,
  room_id     BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  name        TEXT,
  started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS sessions_room_open_idx ON sessions(room_id) WHERE ended_at IS NULL;

-- Historia pokoju czyta sesje po `room_id`, od najnowszej. Powyższy indeks
-- obejmuje tylko sesje otwarte, więc bez tego lista rosłaby w seq scan.
CREATE INDEX IF NOT EXISTS sessions_room_recent_idx ON sessions(room_id, started_at DESC);

-- Liczby i tylko liczby.
--
-- Kolumny na treść dyktowania tu NIE MA i jej brak jest częścią kontraktu
-- prywatności, a nie przeoczeniem: nagranie i tekst nigdy nie opuszczają
-- urządzenia użytkownika. Dopisanie takiej kolumny wymaga migracji, którą ktoś
-- musi świadomie napisać i zatwierdzić — i o to chodzi.
CREATE TABLE IF NOT EXISTS dictations (
  id          BIGSERIAL PRIMARY KEY,
  session_id  BIGINT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  at          TIMESTAMPTZ NOT NULL,
  seconds     REAL NOT NULL,
  words       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS dictations_session_idx ON dictations(session_id);
