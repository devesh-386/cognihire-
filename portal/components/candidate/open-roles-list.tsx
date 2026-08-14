'use client'

import Link from 'next/link'
import { ArrowRight, Loader2, TriangleAlert } from 'lucide-react'
import { listOpenRoles } from '@/lib/gateway'
import { useWorkspaceQuery } from '@/lib/use-workspace-query'

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

  const roles = state.data.roles ?? []

  if (roles.length === 0) {
    return (
      <p className={className}>
        <span className="block rounded-lg border border-border bg-muted px-4 py-3 text-sm text-muted-foreground">
          No open roles right now — check back soon.
        </span>
      </p>
    )
  }

  return (
    <ul className={`flex flex-col divide-y divide-border rounded-lg border border-border ${className ?? ''}`}>
      {roles.map((role: { id: string; title: string; organization_name: string }) => (
        <li key={role.id}>
          <Link
            href={`/apply/${role.id}`}
            className="flex items-center justify-between gap-3 px-4 py-3 text-sm hover:bg-muted"
          >
            <span>
              <span className="font-medium">{role.title}</span>
              <span className="block text-xs text-muted-foreground">{role.organization_name}</span>
            </span>
            <ArrowRight aria-hidden="true" className="size-4 shrink-0 text-muted-foreground" />
          </Link>
        </li>
      ))}
    </ul>
  )
}
