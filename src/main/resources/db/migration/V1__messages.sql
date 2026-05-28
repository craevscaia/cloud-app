CREATE TABLE messages (
    id BIGSERIAL PRIMARY KEY,
    text TEXT NOT NULL CHECK (length(text) > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
