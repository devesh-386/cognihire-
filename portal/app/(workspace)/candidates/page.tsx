'use client'

import { useMemo, useState } from 'react'
import { Loader2, TriangleAlert } from 'lucide-react'
import { EmptyState, WorkspaceBody, WorkspaceHeader } from '@/components/app/app-shell'
import { StatusPill, type PillTone } from '@/components/app/status-pill'
import { SearchField } from '@/components/app/search-field'
import { InviteCandidate } from '@/components/app/invite-candidate'
import { useWorkspaceQuery } from '@/lib/use-workspace-query'
import { listCandidates, listRoles } from '@/lib/gateway'

const PROCESSING_LABEL: Record<string, { label: string; tone: PillTone }> = {
  READY_FOR_INTERVIEW: { label: 'Ready for interview', tone: 'positive' },
  FAILED: { label: 'Processing failed', tone: 'negative' },
  PROCESSING: { label: 'Processing…', tone: 'neutral' },
}

function processingPill(status: string | null) {
  if (!status) return { label: 'Resume not processed yet', tone: 'neutral' as PillTone }
  return PROCESSING_LABEL[status] ?? { label: status, tone: 'neutral' as PillTone }
}

// Roles ride along with the candidate list because issuing a code needs one:
// a code carries the role's title and required skills into the interview
// plan. Fetched together so the "Generate code" control is never briefly
// rendered claiming there are no roles while its own request is still in
// flight.
async function loadCandidates() {
  const [candidates, roles] = await Promise.all([listCandidates(), listRoles()])
  return {
    candidates: candidates.candidates ?? [],
    roles: roles.roles ?? [],
  }
}

export default function CandidatesPage() {
  const state = useWorkspaceQuery(loadCandidates, [])
  const [query, setQuery] = useState('')

  const candidates = state.status === 'ready' ? state.data.candidates : []
  const roles = state.status === 'ready' ? state.data.roles : []
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return candidates
    return candidates.filter(
      (c: any) => c.name?.toLowerCase().includes(q) || c.email?.toLowerCase().includes(q),
    )
  }, [candidates, query])

  return (
    <>
      <WorkspaceHeader
        title="Candidates"
        description="Each candidate arrives with the claims stated in their application, ready to be questioned."
      />
      <WorkspaceBody>
        {state.status === 'loading' ? (
          <div className="flex items-center gap-2.5 rounded-xl border border-border bg-card px-6 py-14 text-sm text-muted-foreground">
            <Loader2 aria-hidden="true" className="size-4 animate-spin" />
            Loading…
          </div>
        ) : state.status === 'error' ? (
          <p
            role="alert"
            className="flex gap-2.5 rounded-lg border border-border bg-muted px-4 py-3 text-xs leading-relaxed text-muted-foreground"
          >
            <TriangleAlert aria-hidden="true" className="mt-px size-4 shrink-0" />
            <span>{state.message}</span>
          </p>
        ) : candidates.length === 0 ? (
          <EmptyState
            title="No candidates yet"
            body="Candidates who register for an interview will appear here automatically."
          />
        ) : (
          <div className="flex flex-col gap-4">
            <SearchField
              value={query}
              onChange={setQuery}
              placeholder="Search by name or email…"
            />
            {filtered.length === 0 ? (
              <EmptyState title="No matches" body="Try a different name or email." />
            ) : (
              <ul className="flex flex-col gap-px overflow-hidden rounded-xl border border-border bg-border">
                {filtered.map((candidate: any) => {
                  const pill = processingPill(candidate.processing_status)
                  return (
                    <li
                      key={candidate.id}
                      className="flex items-center justify-between gap-4 bg-card px-5 py-4"
                    >
                      <div className="min-w-0">
                        <p className="text-sm font-medium tracking-[-0.01em]">{candidate.name}</p>
                        <p className="mt-1 text-sm text-muted-foreground">{candidate.email}</p>
                        <div className="mt-2">
                          <StatusPill label={pill.label} tone={pill.tone} />
                        </div>
                      </div>
                      <InviteCandidate
                        candidateId={candidate.id}
                        candidateName={candidate.name}
                        roles={roles}
                      />
                    </li>
                  )
                })}
              </ul>
            )}
          </div>
        )}
      </WorkspaceBody>
    </>
  )
}
