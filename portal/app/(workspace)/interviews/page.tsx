'use client'

import { useMemo, useState } from 'react'
import Link from 'next/link'
import { Loader2, TriangleAlert } from 'lucide-react'
import { EmptyState, WorkspaceBody, WorkspaceHeader } from '@/components/app/app-shell'
import { StatusPill, type PillTone } from '@/components/app/status-pill'
import { SearchField } from '@/components/app/search-field'
import { useWorkspaceQuery } from '@/lib/use-workspace-query'
import { listCandidates, listInterviewCodes, listInterviews } from '@/lib/gateway'

const STATUS_PILL: Record<string, { label: string; tone: PillTone }> = {
  not_started: { label: 'Not started', tone: 'neutral' },
  in_progress: { label: 'In progress', tone: 'neutral' },
  complete: { label: 'Complete', tone: 'positive' },
  abandoned: { label: 'Abandoned', tone: 'negative' },
}

const EMAIL_PILL: Record<string, { label: string; tone: PillTone }> = {
  sent: { label: 'Invitation sent', tone: 'positive' },
  failed: { label: 'Invitation failed', tone: 'negative' },
  pending: { label: 'Invitation pending', tone: 'neutral' },
}

async function loadInterviewsWorkspace() {
  const [interviews, candidates, codes] = await Promise.all([
    listInterviews(),
    listCandidates(),
    listInterviewCodes(),
  ])
  const candidateById = new Map((candidates.candidates ?? []).map((c: any) => [c.id, c]))
  const codeBySessionId = new Map(
    (codes.interview_codes ?? []).filter((c: any) => c.session_id).map((c: any) => [c.session_id, c]),
  )
  const sessions = (interviews.interviews ?? []).map((session: any) => ({
    ...session,
    candidate: candidateById.get(session.candidate_id) ?? null,
    code: codeBySessionId.get(session.id) ?? null,
  }))
  return { sessions }
}

export default function InterviewsPage() {
  const state = useWorkspaceQuery(loadInterviewsWorkspace, [])
  const [query, setQuery] = useState('')

  const sessions = state.status === 'ready' ? state.data.sessions : []
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return sessions
    return sessions.filter(
      (s: any) =>
        s.candidate?.name?.toLowerCase().includes(q) ||
        s.candidate?.email?.toLowerCase().includes(q) ||
        s.role_title?.toLowerCase().includes(q),
    )
  }, [sessions, query])

  return (
    <>
      <WorkspaceHeader
        title="Interviews"
        description="One interview code per candidate. Candidates complete the session in their browser after a camera and microphone check."
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
        ) : sessions.length === 0 ? (
          <EmptyState
            title="No interviews yet"
            body="Interview sessions started by candidates will appear here."
          />
        ) : (
          <div className="flex flex-col gap-4">
            <SearchField
              value={query}
              onChange={setQuery}
              placeholder="Search by candidate or role…"
            />
            {filtered.length === 0 ? (
              <EmptyState title="No matches" body="Try a different candidate or role." />
            ) : (
              <ul className="flex flex-col gap-px overflow-hidden rounded-xl border border-border bg-border">
                {filtered.map((session: any) => {
                  const statusPill = STATUS_PILL[session.status] ?? {
                    label: session.status,
                    tone: 'neutral' as PillTone,
                  }
                  const emailPill = session.code?.invitation_status
                    ? EMAIL_PILL[session.code.invitation_status]
                    : null
                  const content = (
                    <div className="flex flex-wrap items-center justify-between gap-3">
                      <div>
                        <p className="text-sm font-medium tracking-[-0.01em]">
                          {session.role_title ?? 'Interview'}
                        </p>
                        <p className="mt-1 text-sm text-muted-foreground">
                          {session.candidate?.name ?? session.candidate_id}
                        </p>
                      </div>
                      <div className="flex items-center gap-2">
                        {emailPill ? <StatusPill label={emailPill.label} tone={emailPill.tone} /> : null}
                        <StatusPill label={statusPill.label} tone={statusPill.tone} />
                      </div>
                    </div>
                  )
                  return (
                    <li key={session.id} className="bg-card px-5 py-4">
                      {session.status === 'complete' ? (
                        <Link
                          href={`/reports/${session.id}`}
                          className="block transition-opacity hover:opacity-70"
                        >
                          {content}
                        </Link>
                      ) : (
                        content
                      )}
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
