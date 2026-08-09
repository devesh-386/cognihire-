'use client'

import Link from 'next/link'
import { ArrowLeft, Loader2, TriangleAlert } from 'lucide-react'
import { WorkspaceBody, WorkspaceHeader } from '@/components/app/app-shell'
import { StatusPill, type PillTone } from '@/components/app/status-pill'
import { useWorkspaceQuery } from '@/lib/use-workspace-query'
import { getReport } from '@/lib/gateway'

const OUTCOME_PILL: Record<string, { label: string; tone: PillTone }> = {
  supported: { label: 'Supported', tone: 'positive' },
  not_supported: { label: 'Not supported', tone: 'negative' },
}

export default function ReportDetailPage({
  params,
}: {
  params: { sessionId: string }
}) {
  const { sessionId } = params
  const state = useWorkspaceQuery(() => getReport(sessionId), [sessionId])

  return (
    <>
      <WorkspaceHeader
        title="Evidence report"
        description="One entry per topic the interview planned to cover — the claim, what was asked, and what the candidate's own answer supports or contradicts. No score."
        action={
          <Link
            href="/reports"
            className="flex items-center gap-1.5 text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
          >
            <ArrowLeft aria-hidden="true" className="size-4" />
            Back to reports
          </Link>
        }
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
        ) : (
          <div className="flex flex-col gap-8">
            <div className="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-border bg-card px-6 py-5">
              <div>
                <p className="text-base font-medium tracking-[-0.01em]">
                  {state.data.role_title ?? 'Interview'}
                </p>
                <p className="mt-1 text-sm text-muted-foreground">
                  {state.data.completion_percent}% of planned topics covered
                </p>
              </div>
              <StatusPill
                label={state.data.status === 'complete' ? 'Complete' : state.data.status}
                tone={state.data.status === 'complete' ? 'positive' : 'neutral'}
              />
            </div>

            <div className="flex flex-col gap-px overflow-hidden rounded-xl border border-border bg-border">
              {(state.data.topics ?? []).map((topic: any) => {
                const outcomePill = topic.outcome ? OUTCOME_PILL[topic.outcome] : null
                return (
                  <div key={topic.topic} className="flex flex-col gap-3 bg-card px-6 py-5">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <p className="label-mono text-muted-foreground">{topic.topic}</p>
                        <p className="mt-1.5 text-sm font-medium tracking-[-0.01em]">
                          {topic.claim_text}
                        </p>
                      </div>
                      {outcomePill ? (
                        <StatusPill label={outcomePill.label} tone={outcomePill.tone} />
                      ) : (
                        <StatusPill label="Not reached" tone="neutral" />
                      )}
                    </div>

                    {topic.evidence_quote ? (
                      <blockquote className="rounded-lg border border-border bg-muted px-4 py-3 text-sm leading-relaxed text-foreground">
                        “{topic.evidence_quote}”
                      </blockquote>
                    ) : null}

                    {topic.reason ? (
                      <p className="text-sm leading-relaxed text-muted-foreground">{topic.reason}</p>
                    ) : null}

                    <div className="flex flex-wrap gap-x-6 gap-y-1 text-xs text-muted-foreground">
                      {topic.confidence != null ? (
                        <span>Confidence: {Math.round(topic.confidence * 100)}%</span>
                      ) : null}
                      {topic.attempts > 0 ? (
                        <span>
                          {topic.attempts} {topic.attempts === 1 ? 'attempt' : 'attempts'}
                        </span>
                      ) : null}
                    </div>
                  </div>
                )
              })}
            </div>

            {state.data.rejected_ungrounded_topics?.length ? (
              <div className="rounded-xl border border-dashed border-border bg-card px-6 py-5">
                <p className="text-sm font-medium tracking-[-0.01em]">
                  Considered and not asked
                </p>
                <p className="mt-1 text-sm leading-relaxed text-muted-foreground">
                  These topics were proposed but discarded because no claim in the résumé
                  grounded them.
                </p>
                <ul className="mt-3 flex flex-col gap-1.5">
                  {state.data.rejected_ungrounded_topics.map((topic: string) => (
                    <li key={topic} className="text-sm text-muted-foreground">
                      · {topic}
                    </li>
                  ))}
                </ul>
              </div>
            ) : null}
          </div>
        )}
      </WorkspaceBody>
    </>
  )
}
