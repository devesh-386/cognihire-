-- Fixture: legitimate disposition-plane table. No evidence-shaped column, no
-- REFERENCES clause at all — self-contained, per ED-14/ED-76.
CREATE TABLE disposition (
    id UUID PRIMARY KEY,
    candidate_ref UUID NOT NULL,
    decided_by UUID NOT NULL,
    decided_at TIMESTAMPTZ NOT NULL
);
