-- Fixture: deliberately violates ED-14. A disposition table referencing an
-- evidence-plane audit — the forbidden join. Used only by
-- tools/lint/test_evidence_disposition_schema.py.
CREATE TABLE disposition (
    id UUID PRIMARY KEY,
    claim_audit_id UUID NOT NULL REFERENCES claim_audit (id),
    decided_at TIMESTAMPTZ NOT NULL
);
