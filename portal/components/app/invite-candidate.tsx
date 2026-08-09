'use client'

import { useState } from 'react'
import { Check, Loader2, TriangleAlert } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { generateInterviewCode } from '@/lib/gateway'

type Role = { id: string; title: string; required_skills?: string[] | string | null }

function skillsOf(role: Role | undefined): string[] {
  if (!role?.required_skills) return []
  return Array.isArray(role.required_skills)
    ? role.required_skills
    : String(role.required_skills)
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
}

/// Mints an interview code for one candidate against one of the org's roles.
///
/// The role is required rather than defaulted: a code carries the role title
/// and required skills into the interview plan, so quietly picking the first
/// role would silently interview someone against a position nobody chose.
/// When the org has no roles yet there is nothing honest to generate against,
/// and the control says so instead of rendering a dead button.
export function InviteCandidate({
  candidateId,
  candidateName,
  roles,
}: {
  candidateId: string
  candidateName?: string
  roles: Role[]
}) {
  const [open, setOpen] = useState(false)
  const [roleId, setRoleId] = useState('')
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [issued, setIssued] = useState<string | null>(null)

  if (issued) {
    return (
      <div className="flex flex-col items-end gap-1">
        <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <Check aria-hidden="true" className="size-3.5" />
          Code issued
        </span>
        <code className="rounded-md bg-muted px-2 py-1 font-mono text-sm tracking-wider">
          {issued}
        </code>
        <span className="text-xs text-muted-foreground">
          Invitation emailed{candidateName ? ` to ${candidateName}` : ''}
        </span>
      </div>
    )
  }

  if (roles.length === 0) {
    return (
      <span className="text-xs text-muted-foreground">
        Create a role first
      </span>
    )
  }

  if (!open) {
    return (
      <Button
        variant="outline"
        onClick={() => setOpen(true)}
        className="h-9 shrink-0 rounded-lg text-xs"
      >
        Generate code
      </Button>
    )
  }

  async function submit() {
    const role = roles.find((r) => r.id === roleId)
    if (!role) return
    setPending(true)
    setError(null)
    try {
      const result = await generateInterviewCode({
        candidateId,
        roleTitle: role.title,
        requiredSkills: skillsOf(role),
      })
      setIssued(result.code)
    } catch (err: any) {
      setPending(false)
      setError(err?.message ?? 'Could not generate a code.')
    }
  }

  return (
    <div className="flex flex-col items-end gap-2">
      <div className="flex items-center gap-2">
        <select
          value={roleId}
          onChange={(e) => setRoleId(e.target.value)}
          disabled={pending}
          aria-label="Role to interview against"
          className="h-9 rounded-lg border border-input bg-background px-2.5 text-xs outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/25"
        >
          <option value="">Select a role…</option>
          {roles.map((role) => (
            <option key={role.id} value={role.id}>
              {role.title}
            </option>
          ))}
        </select>
        <Button
          onClick={submit}
          disabled={pending || !roleId}
          className="h-9 shrink-0 rounded-lg text-xs"
        >
          {pending ? (
            <>
              <Loader2 aria-hidden="true" className="size-3.5 animate-spin" />
              Generating…
            </>
          ) : (
            'Generate'
          )}
        </Button>
        {!pending ? (
          <Button
            variant="ghost"
            onClick={() => {
              setOpen(false)
              setError(null)
            }}
            className="h-9 shrink-0 rounded-lg text-xs text-muted-foreground"
          >
            Cancel
          </Button>
        ) : null}
      </div>
      {error ? (
        <p
          role="alert"
          className="flex max-w-xs gap-1.5 text-right text-xs leading-relaxed text-muted-foreground"
        >
          <TriangleAlert aria-hidden="true" className="mt-px size-3.5 shrink-0" />
          <span>{error}</span>
        </p>
      ) : null}
    </div>
  )
}
