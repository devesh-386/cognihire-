'use client'

import { useEffect, useState, type ReactNode } from 'react'
import { Loader2, TriangleAlert } from 'lucide-react'
import { EmptyState } from '@/components/app/app-shell'

export function WorkspaceList<T>({
  fetcher,
  resourceKey,
  emptyTitle,
  emptyBody,
  renderItem,
}: {
  fetcher: () => Promise<Record<string, T[]>>
  resourceKey: string
  emptyTitle: string
  emptyBody: string
  renderItem: (item: T) => ReactNode
}) {
  const [state, setState] = useState<
    | { status: 'loading' }
    | { status: 'error'; message: string }
    | { status: 'ready'; items: T[] }
  >({ status: 'loading' })

  useEffect(() => {
    let cancelled = false
    fetcher()
      .then((result) => {
        if (cancelled) return
        setState({ status: 'ready', items: result[resourceKey] ?? [] })
      })
      .catch((error: any) => {
        if (cancelled) return
        setState({
          status: 'error',
          message: error?.message ?? 'Something went wrong.',
        })
      })
    return () => {
      cancelled = true
    }
  }, [fetcher, resourceKey])

  if (state.status === 'loading') {
    return (
      <div className="flex items-center gap-2.5 rounded-xl border border-border bg-card px-6 py-14 text-sm text-muted-foreground">
        <Loader2 aria-hidden="true" className="size-4 animate-spin" />
        Loading…
      </div>
    )
  }

  if (state.status === 'error') {
    return (
      <p
        role="alert"
        className="flex gap-2.5 rounded-lg border border-border bg-muted px-4 py-3 text-xs leading-relaxed text-muted-foreground"
      >
        <TriangleAlert aria-hidden="true" className="mt-px size-4 shrink-0" />
        <span>{state.message}</span>
      </p>
    )
  }

  if (state.items.length === 0) {
    return <EmptyState title={emptyTitle} body={emptyBody} />
  }

  return (
    <ul className="flex flex-col gap-px overflow-hidden rounded-xl border border-border bg-border">
      {state.items.map((item, index) => (
        <li key={index} className="bg-card px-5 py-4">
          {renderItem(item)}
        </li>
      ))}
    </ul>
  )
}
