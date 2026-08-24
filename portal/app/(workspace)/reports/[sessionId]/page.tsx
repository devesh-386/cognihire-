'use client'

import { use } from 'react'
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
  // Next 15: route params reach the component as a Promise, unwrapped with
  // React's use() hook in a client component (the async/await form the
  // sibling apply/[roleId] server component uses isn't available here).
  params: Promise<{ sessionId: string }>
}) {
  const { sessionId } = use(params)
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

            {state.data.transparency ? (
              <TransparencyPanel t={state.data.transparency} />
            ) : null}

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
                      {topic.heuristic_similarity != null ? (
                        <span>
                          Similarity (unverified, model unavailable):{' '}
                          {Math.round(topic.heuristic_similarity * 100)}%
                        </span>
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

type Transparency = {
  planned_by: string
  used_ai_planner: boolean
  planning_degraded_reason: string | null
  topics_planned: number
  topics_grounding_rejected: number
  grounding_rate: number
  topics_examined: number
  topics_with_direct_evidence: number
  supported: number
  not_supported: number
  mean_confidence: number | null
  topics_graded_by_heuristic: number
  claims_truncated: boolean
  topics_truncated: boolean
}

const PLANNER_LABEL: Record<string, string> = {
  hosted_llm: 'Hosted AI model',
  local_llm: 'Local AI model',
  heuristic_rule: 'Deterministic fallback',
}

function TransparencyPanel({ t }: { t: Transparency }) {
  const stats: { label: string; value: string; hint?: string }[] = [
    {
      label: 'Planned by',
      value: PLANNER_LABEL[t.planned_by] ?? t.planned_by,
    },
    {
      label: 'Grounding rate',
      value: `${Math.round(t.grounding_rate * 100)}%`,
      hint:
        t.topics_grounding_rejected > 0
          ? `${t.topics_grounding_rejected} proposed topic${t.topics_grounding_rejected === 1 ? '' : 's'} rejected as ungrounded`
          : 'Every proposed topic traced to a claim',
    },
    {
      label: 'Backed by a quote',
      value: `${t.topics_with_direct_evidence} / ${t.topics_examined}`,
      hint: 'Examined topics with a verbatim evidence quote',
    },
    {
      label: 'Mean confidence',
      value: t.mean_confidence != null ? `${Math.round(t.mean_confidence * 100)}%` : '—',
      hint:
        t.topics_graded_by_heuristic > 0
          ? `Model confidence across examined topics — excludes ${t.topics_graded_by_heuristic} graded by the deterministic fallback while the model was unavailable`
          : 'Model confidence across examined topics',
    },
  ]

  return (
    <section
      aria-label="How this report was produced"
      className="rounded-xl border border-border bg-card px-6 py-5"
    >
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="label-mono text-muted-foreground">How this report was produced</p>
        <p className="text-xs text-muted-foreground">
          Disclosure of process — not a score.
        </p>
      </div>

      {!t.used_ai_planner && t.planning_degraded_reason ? (
        <p className="mt-4 rounded-lg border border-dashed border-border bg-muted px-4 py-3 text-xs leading-relaxed text-muted-foreground">
          This interview was planned by the deterministic fallback, not an AI
          model: {t.planning_degraded_reason}. It covers real claims but without
          a model&apos;s reasoning about which matter most.
        </p>
      ) : null}

      {t.claims_truncated || t.topics_truncated ? (
        <p className="mt-4 rounded-lg border border-dashed border-border bg-muted px-4 py-3 text-xs leading-relaxed text-muted-foreground">
          {t.claims_truncated && t.topics_truncated
            ? 'The candidate had more usable claims and more proposed topics than this interview was built from — both were capped.'
            : t.claims_truncated
            ? 'The candidate had more usable claims than this interview was built from — the claim list was capped.'
            : 'The planner proposed more topics than this interview was built from — the topic list was capped.'}{' '}
          This is not full coverage of everything the candidate claimed.
        </p>
      ) : null}

      <dl className="mt-4 grid grid-cols-2 gap-px overflow-hidden rounded-lg border border-border bg-border sm:grid-cols-4">
        {stats.map((s) => (
          <div key={s.label} className="flex flex-col gap-1 bg-card px-4 py-3.5">
            <dt className="text-xs text-muted-foreground">{s.label}</dt>
            <dd className="text-lg font-medium tracking-[-0.02em] tabular-nums">
              {s.value}
            </dd>
            {s.hint ? (
              <dd className="text-[0.6875rem] leading-snug text-muted-foreground">
                {s.hint}
              </dd>
            ) : null}
          </div>
        ))}
      </dl>

      <p className="mt-3 text-xs leading-relaxed text-muted-foreground">
        {t.supported} supported · {t.not_supported} not supported · {t.topics_examined} of{' '}
        {t.topics_planned} planned topics examined
      </p>
    </section>
  )
}
