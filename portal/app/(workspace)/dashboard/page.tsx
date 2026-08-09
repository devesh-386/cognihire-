'use client'

import Link from 'next/link'
import { AlertTriangle, Loader2, TriangleAlert } from 'lucide-react'
import { WorkspaceBody, WorkspaceHeader } from '@/components/app/app-shell'
import { useWorkspaceQuery } from '@/lib/use-workspace-query'
import { listCandidates, listInterviewCodes, listInterviews, listRoles } from '@/lib/gateway'

async function loadDashboard() {
  const [roles, candidates, interviews, codes] = await Promise.all([
    listRoles(),
    listCandidates(),
    listInterviews(),
    listInterviewCodes(),
  ])
  return {
    roles: roles.roles ?? [],
    candidates: candidates.candidates ?? [],
    interviews: interviews.interviews ?? [],
    codes: codes.interview_codes ?? [],
  }
}

const shortcuts = [
  { href: '/roles', title: 'Roles', body: 'Define what a position requires before candidates arrive.' },
  { href: '/candidates', title: 'Candidates', body: 'Applications with claims parsed from their resume.' },
  { href: '/interviews', title: 'Interviews', body: 'Track sessions as candidates complete them.' },
  { href: '/reports', title: 'Reports', body: 'Read the evidence trail behind each conclusion.' },
]

function StatCard({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex flex-col gap-1.5 bg-card p-6">
      <span className="label-mono text-muted-foreground">{label}</span>
      <span className="text-2xl font-medium tracking-[-0.02em]">{value}</span>
    </div>
  )
}

export default function DashboardPage() {
  const state = useWorkspaceQuery(loadDashboard, [])

  const attention =
    state.status === 'ready'
      ? [
          ...state.data.candidates
            .filter((c: any) => c.processing_status === 'FAILED')
            .map((c: any) => ({
              key: `candidate-${c.id}`,
              text: `${c.name}'s resume failed to process`,
              href: '/candidates',
            })),
          ...state.data.codes
            .filter((code: any) => code.invitation_status === 'failed')
            .map((code: any) => ({
              key: `code-${code.id}`,
              text: `Invitation email failed for ${code.role_title ?? 'a candidate'}`,
              href: '/interviews',
            })),
          ...state.data.interviews
            .filter((s: any) => s.status === 'abandoned')
            .map((s: any) => ({
              key: `session-${s.id}`,
              text: `Interview for ${s.role_title ?? 'a role'} was abandoned`,
              href: '/interviews',
            })),
        ]
      : []

  return (
    <>
      <WorkspaceHeader title="Overview" description="What's happening across your organization right now." />
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
            <div className="grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-border bg-border sm:grid-cols-4">
              <StatCard label="Roles" value={state.data.roles.length} />
              <StatCard label="Candidates" value={state.data.candidates.length} />
              <StatCard
                label="Interviews in progress"
                value={state.data.interviews.filter((s: any) => s.status === 'in_progress').length}
              />
              <StatCard
                label="Completed interviews"
                value={state.data.interviews.filter((s: any) => s.status === 'complete').length}
              />
            </div>

            {state.data.roles.length === 0 && state.data.candidates.length === 0 ? (
              <div className="rounded-xl border border-dashed border-border bg-card p-6 sm:p-7">
                <h2 className="text-base font-medium tracking-[-0.01em]">
                  Start here
                </h2>
                <p className="mt-2 max-w-xl text-sm leading-relaxed text-muted-foreground">
                  Nothing has been set up for this organization yet. An
                  interview is grounded against a role, so that comes first.
                </p>
                <ol className="mt-5 flex flex-col gap-3">
                  {[
                    'Define a role — what the position actually requires.',
                    'A candidate registers and their résumé is parsed into claims.',
                    'Generate their interview code from Candidates; the invitation is emailed automatically.',
                    'Read the evidence trail in Reports once they finish.',
                  ].map((step, index) => (
                    <li
                      key={step}
                      className="flex gap-3 text-sm leading-relaxed text-muted-foreground"
                    >
                      <span className="label-mono shrink-0 text-muted-foreground">
                        {String(index + 1).padStart(2, '0')}
                      </span>
                      {step}
                    </li>
                  ))}
                </ol>
                <div className="mt-6">
                  <Link
                    href="/roles"
                    className="text-sm font-medium underline underline-offset-4 hover:opacity-70"
                  >
                    Go to Roles
                  </Link>
                </div>
              </div>
            ) : null}

            {attention.length > 0 ? (
              <div>
                <h2 className="text-sm font-medium tracking-[-0.01em]">Needs attention</h2>
                <ul className="mt-3 flex flex-col gap-px overflow-hidden rounded-xl border border-border bg-border">
                  {attention.map((item) => (
                    <li key={item.key} className="bg-card px-5 py-4">
                      <Link
                        href={item.href}
                        className="flex items-center gap-3 text-sm transition-opacity hover:opacity-70"
                      >
                        <AlertTriangle aria-hidden="true" className="size-4 shrink-0 text-destructive" />
                        {item.text}
                      </Link>
                    </li>
                  ))}
                </ul>
              </div>
            ) : null}

            <div>
              <h2 className="text-sm font-medium tracking-[-0.01em]">Workspace</h2>
              <div className="mt-3 grid gap-px overflow-hidden rounded-xl border border-border bg-border sm:grid-cols-2">
                {shortcuts.map((shortcut) => (
                  <Link
                    key={shortcut.href}
                    href={shortcut.href}
                    className="group flex flex-col gap-2 bg-card p-6 transition-colors hover:bg-accent/40"
                  >
                    <span className="text-sm font-medium tracking-[-0.01em]">{shortcut.title}</span>
                    <span className="text-sm leading-relaxed text-muted-foreground">{shortcut.body}</span>
                  </Link>
                ))}
              </div>
            </div>
          </div>
        )}
      </WorkspaceBody>
    </>
  )
}
