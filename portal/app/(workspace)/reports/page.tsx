'use client'

import Link from 'next/link'
import { Loader2, TriangleAlert } from 'lucide-react'
import { EmptyState, WorkspaceBody, WorkspaceHeader } from '@/components/app/app-shell'
import { useWorkspaceQuery } from '@/lib/use-workspace-query'
import { listCandidates, listReports } from '@/lib/gateway'

async function loadReportsWorkspace() {
  const [reports, candidates] = await Promise.all([listReports(), listCandidates()])
  const candidateById = new Map((candidates.candidates ?? []).map((c: any) => [c.id, c]))
  const sessions = (reports.reports ?? []).map((session: any) => ({
    ...session,
    candidate: candidateById.get(session.candidate_id) ?? null,
  }))
  return { sessions }
}

export default function ReportsPage() {
  const state = useWorkspaceQuery(loadReportsWorkspace, [])
  const sessions = state.status === 'ready' ? state.data.sessions : []

  return (
    <>
      <WorkspaceHeader
        title="Reports"
        description="Each report traces a claim to the question it prompted and the answer that supports or contradicts it. No overall score is produced."
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
            title="No reports yet"
            body="Evidence reports appear here once an interview session completes."
          />
        ) : (
          <ul className="flex flex-col gap-px overflow-hidden rounded-xl border border-border bg-border">
            {sessions.map((session: any) => (
              <li key={session.id} className="bg-card px-5 py-4">
                <Link
                  href={`/reports/${session.id}`}
                  className="flex items-center justify-between gap-4 transition-opacity hover:opacity-70"
                >
                  <div>
                    <p className="text-sm font-medium tracking-[-0.01em]">
                      {session.role_title ?? 'Interview'}
                    </p>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {session.candidate?.name ?? session.candidate_id}
                    </p>
                  </div>
                  <span className="label-mono text-muted-foreground">View report →</span>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </WorkspaceBody>
    </>
  )
}
