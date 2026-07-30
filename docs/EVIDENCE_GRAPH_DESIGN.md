# Evidence Graph — Design

Status: **design only, not implemented.** Unlike the Claim Extraction and
Adaptive Interview designs, almost nothing here is blocked on an LLM key —
this is a representation and storage layer over evidence that already
exists (`ClaimEvidence`, `VerificationResult`, `AskedFollowUp`) or will exist
once those two designs are built. It's the most immediately buildable of the
three.

## The actual upgrade this represents

Today, whether a piece of evidence *supports* or *contradicts* a claim lives
entirely inside `ClaimEvidence.observation` — a sentence. A human reads
"340 characters were added in one step, then explained on request" and
infers, from English, that this is corroborating. That inference is never
written down as a fact anywhere.

The graph makes that relationship a **first-class, typed, cited fact** for
the first time. Not a new judgment the system makes — the same judgments
already happening (a dimension-adequacy check, a telemetry trigger, a
reviewer's read) get a place to live as structured data instead of only as
prose. This is additive: `ClaimAudit`, `ClaimEvidence`, `VerificationResult`
remain the source of truth for what happened. The graph wraps each existing
evidence item as a node and adds the previously-implicit relationships as
explicit, traceable edges. It does not replace the audit; it's a second,
richer view over the same facts, alongside the existing report (see
Visualization, below).

---

## Explainability constraints — stated as checkable properties, not a vibe

1. **Every edge type is one of a small, closed, fully-enumerable set** (seven
   below) — a UI can always render a complete legend; nothing is emergent or
   unlisted.
2. **Every edge carries a required, non-empty `rationale` string** — a human
   sentence explaining why the edge exists. Enforced at the schema level: an
   edge without one is a malformed record, not "no rationale needed," the
   same way `Unchecked` cannot have a similarity value.
3. **Every node and edge carries a `basis`** — a closed enum stating what
   *kind* of thing produced it (a specific bounded LLM judgment, a
   deterministic telemetry rule, a human reviewer, an identity-check result).
   Never a vague "the system decided."
4. **No numeric weight is ever stored on an edge.** Where a rendering layer
   needs a number (a force-directed layout wants *something* to size spring
   tension by), that number is computed transiently, at draw time, from a
   fixed and visible edge-type → layout-weight lookup table — never
   persisted, never displayed, and never read by anything that decides claim
   status. This is stated explicitly because it's the most likely place for
   a hidden weight to sneak back in later under a different name.
5. **No graph algorithm computes an aggregate "claim strength" score** —
   specifically: do not run PageRank, betweenness centrality, or any
   node-ranking algorithm over support/contradict edges and present the
   result as a confidence or strength number. That is a hidden weight with
   extra steps, and it violates this design's whole premise as surely as a
   bare LLM-reported float would. Query the graph and return the actual
   nodes/edges with their rationale text — never a reduction to one number.
6. **Traversal returns evidence, not aggregates.** "Show everything that
   contradicts this claim" returns the contradicting nodes and their
   rationale, in full — never a count-weighted summary.

---

## Node types

Every node belongs to exactly one claim's examination (this system is
claim-centric, matching `ClaimAudit` already being organized per claim). Five
of seven wrap an existing type directly; one is a natural promotion of data
that already exists but isn't yet first-class; one is genuinely new.

| Node type | Wraps | Payload |
|---|---|---|
| `resumeClaim` | `Claim` (existing) | `{ claimId, text, source, skill, claimType?, evidenceRequirement? }` — the last two once Claim Extraction ships |
| `interviewAnswer` | promoted from `InterviewController._answersByClaim` | `{ claimId, text, capturedAt }` — today only the latest answer is kept; the graph wants each submitted answer as its own node |
| `identityCheck` | `VerificationResult` (existing, direct) | `{ result: Verified\|Mismatch\|Unchecked (same sealed shape), at }` |
| `codeEvidence` | new — a specific citable span, not the whole answer | `{ claimId, quotedSpan, charStart, charEnd, capturedAt }` |
| `telemetry` | `ProcessSignals`/`EditEvent` (existing, direct) | `{ signals: ProcessSignals-shaped snapshot, capturedAt }` |
| `followUpQuestion` | `AskedFollowUp` (existing, direct) | `{ question, trigger, observation, response?, wasAnswered, askedAt }` |
| `reviewerComment` | new | `{ reviewerName, text, createdAt }` |

**`codeEvidence` vs. `interviewAnswer`:** the answer node is the whole
submitted response; code evidence is the *specific span* a follow-up
actually asks about (typically the bulk-insert span `FollowUpGenerator`
already flags via `spansWorthProbing()`) — a precise citation, mirroring the
byte-exact span verification already designed for Claim Extraction, rather
than "somewhere in this answer."

**`identityCheck` relates to answers, not directly to claims.** Identity
verification runs continuously through the whole session, not "about" any
one claim. So an identity-check node's edge target is whichever
`interviewAnswer` (or `followUpQuestion` response) was being *written* during
that check's timestamp window — this is more precise than today's report,
which only shows a session-wide identity-coverage count. The graph can show
exactly which specific answer occurred during a mismatch or a gap, which is
genuinely more useful evidence than an aggregate.

**`reviewerComment` has an honest gap, flagged rather than papered over:**
there is no reviewer-auth system in this prototype yet. `reviewerName` is
free text until one exists. Noted here so it isn't quietly assumed to be
more trustworthy than it is.

---

## Edge types and direction convention

Convention: an edge points from the newer/dependent node **toward** the node
it relates to — `derivedFrom` points toward the cause, `supports`/
`contradicts`/`corroborates` point toward the claim (or another evidence
node, for corroboration chains), `probes` points from question toward the
evidence it targets, `annotates` points from the comment toward whatever it
comments on.

| Edge type | Meaning | Typical basis |
|---|---|---|
| `supports` | Target node substantiates the claim/dimension | `llmDimensionJudgment`, `identityCheckResult` |
| `partiallySupports` | Touches the claim/dimension but stays generic | `llmDimensionJudgment` |
| `contradicts` | Conflicts with the target | `llmContradictionCheck`, `identityCheckResult` |
| `corroborates` | Two evidence nodes reinforce each other (not a claim edge) | `llmContradictionCheck` (result: consistent), `telemetryRule` |
| `probes` | A question targets a piece of evidence, not yet resolved | `telemetryRule`, `systemDerivation` |
| `annotates` | A reviewer comment attaches to any node — observational, not a verdict | `reviewerAuthored` |
| `derivedFrom` | Mechanical provenance: why this node exists at all | `systemDerivation` |

`derivedFrom` is deliberately separate from the evidentiary edges
(`supports`/`contradicts`/`corroborates`/`partiallySupports`): it answers
"why does this node exist" (system mechanics — a follow-up exists because
telemetry triggered it), while the evidentiary edges answer "what does this
evidence mean" (a human reasons with it). Both satisfy "traceable," for two
different senses of the word.

`EdgeBasis` enum, in full — every edge declares exactly one:

```
llmDimensionJudgment   — the bounded adequacy judge from the Adaptive
                          Interview design (addressed/partial/not_addressed)
llmContradictionCheck  — the bounded contradiction check from the same design
telemetryRule           — a deterministic FollowUpGenerator trigger
identityCheckResult     — a VerificationResult itself, no LLM involved
reviewerAuthored        — a human typed this
systemDerivation        — mechanical fact, no judgment (e.g. "this span is
                          what this telemetry measurement describes")
```

Note how little of this is new machinery: `llmDimensionJudgment` and
`llmContradictionCheck` are literally the two bounded LLM calls already
designed in `ADAPTIVE_INTERVIEW_ENGINE_DESIGN.md` — their categorical output
(`addressed`/`partial`/`not_addressed`, `consistent`/`contradicts`/`unclear`)
maps onto edge types directly. The graph doesn't invent a new judgment
mechanism; it gives the existing ones a place to be recorded as data.

---

## Worked example — the distributed-cache claim, end to end

```
 [resumeClaim N1] "I designed a distributed cache"
        ▲                                    ▲
        │ supports (llmDimensionJudgment,     │ supports (llmDimensionJudgment,
        │  dim=Technology: "names Redis        │  dim=Consistency+Tradeoffs: "explains
        │  Cluster + consistent hashing")       │  consistent hashing vs range
        │                                       │  partitioning tradeoff")
 [interviewAnswer N2] ──corroborates──▶ [interviewAnswer N6]
        ▲                                    ▲
        │ supports                            │ supports
        │ (identityCheckResult)                │ (identityCheckResult)
 [identityCheck N7: Verified]          [identityCheck N8: Verified]
  "verified during the window                  ▲
   N2 was being written"                       │ annotates (reviewerAuthored)
                                        [reviewerComment N9]
                                         "rebalancing explanation was
                                          genuinely specific"

 [telemetry N4: 340-char bulk insert,
  preceded by a 35s pause]
        ▲
        │ derivedFrom (systemDerivation)
 [codeEvidence N3: the quoted 340-char span]
        ▲
        │ probes (telemetryRule — pauseThenBulk trigger)
 [followUpQuestion N5] "Walk me through the part you just added —
                          what were you working out during the pause?"
        │
        └── N6 is the answer TO N5
```

If instead N8 had come back `Mismatch` during N6's window, that edge would
be `identityCheck --contradicts--> interviewAnswer(N6)` with basis
`identityCheckResult` — the graph would show precisely that *this specific
answer's* authorship is in question, not a vague session-wide flag.

---

## Data structures

```dart
enum NodeType {
  resumeClaim, interviewAnswer, identityCheck, codeEvidence,
  telemetry, followUpQuestion, reviewerComment,
}

enum EdgeType {
  supports, partiallySupports, contradicts, corroborates,
  probes, annotates, derivedFrom,
}

enum EdgeBasis {
  llmDimensionJudgment, llmContradictionCheck, telemetryRule,
  identityCheckResult, reviewerAuthored, systemDerivation,
}

class GraphNode {
  final String id;
  final String claimId;       // every node belongs to one claim's examination
  final NodeType type;
  final Map<String, Object?> payload;  // discriminated by `type`, shapes above
  final DateTime createdAt;
  final String? sourceRef;    // pointer back into existing data — e.g. the
                              // specific VerificationResult or AskedFollowUp
                              // this node wraps. The graph indexes existing
                              // evidence; it does not duplicate its meaning.
}

class GraphEdge {
  final String id;
  final String fromNodeId;
  final String toNodeId;
  final EdgeType type;
  final String rationale;     // required, non-empty — enforced at decode time
  final EdgeBasis basis;
  final DateTime createdAt;
  final String createdBy;     // model-version string, or reviewer name/id
}

class EvidenceGraph {
  final String claimId;
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  List<GraphEdge> edgesInto(String nodeId) =>
      edges.where((e) => e.toNodeId == nodeId).toList();
  List<GraphEdge> edgesOfType(EdgeType type) =>
      edges.where((e) => e.type == type).toList();
  // Deliberately no `strength(nodeId)` or `centrality(nodeId)` method.
  // Any future contributor reaching for one should read constraint 5 above.
}
```

Decoding follows the exact discipline already established in
`core/persistence/json_codec.dart`: unknown `NodeType`/`EdgeType`/`EdgeBasis`
value → throw, never default. Missing or empty `rationale` → throw, an edge
without one is corrupt, not "unannotated." Same reasoning as `Unchecked`
never fabricating a similarity value.

---

## Database

**Phase 1 — now, matches actual scale.** JSON documents, same discipline as
the existing `JsonFileAuditStore`: one `{claimId}.graph.json` file per claim
examination, `nodes[]`/`edges[]` arrays, atomic write (temp + rename), strict
decode. Zero new infrastructure, consistent with this project's existing
call on the export format ("a stored audit a reviewer can open in a text
editor is worth more... than query performance it will never need") — the
same reasoning applies to standing up a graph database for a ~50-candidate
demo.

The schema is deliberately shaped as if it were relational tables from day
one — flat records, `fromNodeId`/`toNodeId` as plain string foreign keys —
so Phase 2 is a mechanical export/import, not a redesign.

**Phase 2 — triggered by an actual need, not a timeline.** If/when
cross-candidate or cross-session graph queries become real (see Future
Extensions), migrate the same shapes into SQLite:

```sql
CREATE TABLE nodes (
  id           TEXT PRIMARY KEY,
  claim_id     TEXT NOT NULL,
  type         TEXT NOT NULL,       -- NodeType, CHECK constraint against the closed enum
  payload_json TEXT NOT NULL,
  source_ref   TEXT,
  created_at   TEXT NOT NULL
);

CREATE TABLE edges (
  id          TEXT PRIMARY KEY,
  from_id     TEXT NOT NULL REFERENCES nodes(id),
  to_id       TEXT NOT NULL REFERENCES nodes(id),
  type        TEXT NOT NULL,        -- EdgeType, CHECK constraint
  rationale   TEXT NOT NULL CHECK (length(rationale) > 0),
  basis       TEXT NOT NULL,        -- EdgeBasis, CHECK constraint
  created_at  TEXT NOT NULL,
  created_by  TEXT NOT NULL
);

CREATE INDEX idx_edges_from ON edges(from_id);
CREATE INDEX idx_edges_to   ON edges(to_id);
CREATE INDEX idx_nodes_claim ON nodes(claim_id);
```

Multi-hop traversal ("everything that eventually feeds into this claim,
however indirectly") via a recursive CTE:

```sql
WITH RECURSIVE upstream(node_id, depth) AS (
  SELECT to_id, 0 FROM edges WHERE to_id = :claimNodeId
  UNION
  SELECT e.from_id, u.depth + 1
  FROM edges e JOIN upstream u ON e.to_id = u.node_id
  WHERE u.depth < 6   -- bounded depth, no unbounded walk
)
SELECT n.*, e.type, e.rationale FROM upstream u
JOIN nodes n ON n.id = u.node_id
JOIN edges e ON e.from_id = u.node_id;
```

Note what this query returns: full rows with `rationale` intact, not a
count or a score.

---

## Flutter visualization

**Layout.** An existing node-link graph layout package (e.g. `graphview` on
pub.dev, or an equivalent — verify current maintenance/API before committing,
not asserted as checked here) for node positioning; custom widgets/painting
for the actual node "chips" and edge styling so the visual language matches
the rest of the app rather than a generic package look.

**Visual language reuses existing conventions**, it doesn't invent a new
color system: green/orange/red/grey for `supports`/`partiallySupports`/
`contradicts`/no-relation, matching the palette already used in
`claim_audit_screen.dart` and `session_history_screen.dart` for
`ClaimStatus`/`ProvenanceQuality`. Node type is encoded by icon + shape
(the same icon-per-`EvidenceKind` pattern already used for
`_evidenceIcon` in the audit screen, extended to seven types instead of
three). Edge style: solid = `supports`/`contradicts`, dashed = `probes`
(pending, unresolved), thin/grey = `annotates`, small distinct arrowhead =
`derivedFrom` (provenance, visually de-emphasized relative to evidentiary
edges since it answers a different question).

**Numeric layout weights are computed at draw time only**, from a fixed,
visible `EdgeType → springWeight` lookup table, purely to make the force
layout legible — never stored, never shown as a number in the UI, never
read by anything that decides claim status. Stated here again because it's
worth restating at the point where an implementer would actually type the
number in.

**Interaction:** tap a node → full payload + every edge touching it, each
with its rationale and basis shown in full text. Tap an edge → its rationale/
basis in a tooltip or bottom sheet. **No summary badge anywhere on the graph
view** — not a "claim strength: 73%," not a colored ring implying an
aggregate. That's the first thing an implementer will want to add for
scanability, and it's exactly what constraint 5 rules out.

**The graph is a second view, not a replacement.** `ClaimAuditScreen` and
the HTML export stay exactly as they are — a linear, time-ordered narrative
is genuinely the right view for a reviewer in a hurry. The graph view is
additive, for a reviewer investigating something specific or a dispute. Both
render from the same `EvidenceGraph`/`ClaimAudit` data; neither is the
"upgraded" replacement for the other.

---

## Export format

Two formats, mirroring the existing pattern of two outputs for two audiences
(`json_codec.dart` for fidelity/reload, `audit_export.dart`/HTML for a human
to read):

**JSON — primary, full-fidelity, canonical.** The exact `nodes[]`/`edges[]`
shape above, versioned (`schemaVersion`) and strictly decoded on reimport
the same way `ClaimAudit` already is. This is what CogniHire itself
re-imports; every field, including `rationale`/`basis`/`createdBy`, survives
exactly.

**GraphML — secondary, interoperability.** An existing open standard
(not invented for this project) so the evidence graph can be opened in
third-party tools (Gephi, yEd, and similar) by an auditor who doesn't have
CogniHire installed — a genuinely useful property for a system whose whole
pitch is that the evidence should survive scrutiny from someone other than
its own vendor.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<graphml xmlns="http://graphml.graphdrawing.org/xmlns">
  <key id="nodeType" for="node" attr.name="nodeType" attr.type="string"/>
  <key id="label"    for="node" attr.name="label"    attr.type="string"/>
  <key id="edgeType" for="edge" attr.name="edgeType" attr.type="string"/>
  <key id="rationale" for="edge" attr.name="rationale" attr.type="string"/>
  <key id="basis"    for="edge" attr.name="basis"    attr.type="string"/>
  <graph id="claim-c1-distributed-cache" edgedefault="directed">
    <node id="N1"><data key="nodeType">resumeClaim</data>
      <data key="label">I designed a distributed cache</data></node>
    <node id="N2"><data key="nodeType">interviewAnswer</data>
      <data key="label">Answer mentioning Redis Cluster, consistent hashing</data></node>
    <edge source="N2" target="N1">
      <data key="edgeType">supports</data>
      <data key="rationale">Names Redis Cluster and consistent hashing, addressing the Technology dimension.</data>
      <data key="basis">llmDimensionJudgment</data>
    </edge>
  </graph>
</graphml>
```

GraphML's attribute typing is more rigid than the internal JSON shape, so it
is explicitly the *secondary* format — reimport for further CogniHire use
should always go through the JSON export, not a round-trip through GraphML.

---

## Future extensions

1. **Cross-candidate pattern queries** (needs the Phase 2 SQLite migration).
   "Show every claim across candidates citing this same repository as code
   evidence" is naturally graph-shaped and wasn't expressible in a flat
   per-session report. Genuinely useful for spotting a templated or
   rehearsed answer reused across candidates — and genuinely something to
   build carefully: cross-candidate matching drifts toward profiling if it
   isn't scoped tightly to concrete, citable overlaps (a repo URL, an exact
   quoted phrase), never to a similarity score.
2. **Cross-session graph diffing**, paired with the "Cross-Session
   Provenance Chain" module from the CogniHire repositioning brief — comparing
   the same candidate's graph across take-home → live interview → onboarding,
   surfacing a genuine node-level `contradicts` edge *between* stages
   (a code-evidence node from the take-home conflicting with a live
   interview-answer node about the same claim) — something a flat report per
   session structurally cannot express.
3. **Candidate right-of-reply**, tied to the repositioning brief's proposed
   "Candidate Disclosure View": a `candidateResponse` node type and an edge
   back to whatever it responds to, giving the candidate a literal,
   structural voice inside the evidence record itself — extending
   "detect, deter, document, never accuse" to include the candidate's own
   account, not just the reviewer's.
4. **Rubric-coverage view.** For a given claim, highlight which
   `EvidenceDimension`s (from Claim Extraction's rubric) have any supporting
   node versus none — still categorical/countable ("2 supporting nodes, 0
   contradicting" vs. "0 nodes at all"), never a weighted completeness score.
5. **A small allow-listed graph query DSL** for reviewers/auditors once the
   SQLite backing exists ("find everything connected to X via Y") rather than
   ad-hoc code per question — a natural extension of the recursive-CTE
   traversal already sketched above.

---

## What's implementable today

This is the least blocked of the four designs so far. The node/edge types,
the strict JSON codec, the Phase-1 file store, the GraphML exporter, and the
Flutter rendering shell (layout + node chips + edge styling + tap
interactions) need no LLM call at all — they're a representation layer over
data this project already has, or will have once Claim Extraction and the
Adaptive Interview Engine are built. The only edges that reference an LLM
judgment (`llmDimensionJudgment`, `llmContradictionCheck`) are populated by
those two designs' bounded calls once they exist; the graph itself doesn't
need to wait on them to be built and tested with fixture data.
