-- Fixture: legitimate evidence-plane table. Not under a "disposition" path,
-- so REFERENCES here is expected and not flagged.
CREATE TABLE claim (
    id UUID PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES interview_session (id),
    text TEXT NOT NULL
);
