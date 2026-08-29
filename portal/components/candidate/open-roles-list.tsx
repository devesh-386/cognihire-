'use client'

import Link from 'next/link'
import { ArrowRight, ExternalLink, Loader2, TriangleAlert } from 'lucide-react'
import { listOpenRoles } from '@/lib/gateway'
import { useWorkspaceQuery } from '@/lib/use-workspace-query'

type OpenRole = {
  id: string
  title: string
  organization_name: string
  // The role's auto-generated Google Form, when its intake has one. Null for
  // a role with no active intake — see main.py's intake_application_url.
  application_url?: string | null
}

export function OpenRolesList({ className }: { className?: string }) {
  const state = useWorkspaceQuery(() => listOpenRoles(), [])

  if (state.status === 'loading') {
    return (
      <p className={`flex items-center gap-2 text-sm text-muted-foreground ${className ?? ''}`}>
        <Loader2 className="size-4 animate-spin" aria-hidden="true" />
        Loading open roles…
      </p>
    )
  }

  if (state.status === 'error') {
    return (
      <p className={`flex items-center gap-2 text-sm text-destructive ${className ?? ''}`}>
        <TriangleAlert className="size-4 shrink-0" aria-hidden="true" />
        {state.message}
      </p>
    )
  }

  const roles: OpenRole[] = state.data.roles ?? []

  if (roles.length === 0) {
    return (
      <p className={className}>
        <span className="block rounded-lg border border-border bg-muted px-4 py-3 text-sm text-muted-foreground">
          No open roles right now — check back soon.
        </span>
      </p>
    )
  }

  const rowClass = 'flex items-center justify-between gap-3 px-4 py-3 text-sm hover:bg-muted'

  return (
    <ul className={`flex flex-col divide-y divide-border rounded-lg border border-border ${className ?? ''}`}>
      {roles.map((role) => {
        // A role whose intake has a generated form sends the candidate to
        // that form — the same one the Apps Script trigger and the intake
        // poller feed into. Only a role without one falls back to the
        // portal's own résumé upload, so the two paths never diverge for
        // the same role.
        const label = (
          <span>
            <span className="font-medium">{role.title}</span>
            <span className="block text-xs text-muted-foreground">
              {role.organization_name}
            </span>
          </span>
        )

        return (
          <li key={role.id}>
            {role.application_url ? (
              <a
                href={role.application_url}
                target="_blank"
                rel="noopener noreferrer"
                className={rowClass}
                data-application-form="google"
              >
                {label}
                <span className="flex shrink-0 items-center gap-2 text-xs text-muted-foreground">
                  Application form
                  <ExternalLink aria-hidden="true" className="size-4" />
                </span>
              </a>
            ) : (
              <Link href={`/apply/${role.id}`} className={rowClass}>
                {label}
                <ArrowRight aria-hidden="true" className="size-4 shrink-0 text-muted-foreground" />
              </Link>
            )}
          </li>
        )
      })}
    </ul>
  )
}
