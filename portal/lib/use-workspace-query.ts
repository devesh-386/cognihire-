'use client'

// Shared loading/error/ready state for pages that need more than one
// gateway call joined together client-side (e.g. interviews + candidates +
// interview-codes) — `components/app/resource-list.tsx`'s WorkspaceList
// covers the single-fetcher case already; this is the same shape for pages
// that can't use it because they combine several real endpoints into one
// view instead of listing one resource.

import { useEffect, useState } from 'react'

export type WorkspaceQueryState<T> =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'ready'; data: T }

export function useWorkspaceQuery<T>(load: () => Promise<T>, deps: unknown[] = []): WorkspaceQueryState<T> {
  const [state, setState] = useState<WorkspaceQueryState<T>>({ status: 'loading' })

  useEffect(() => {
    let cancelled = false
    setState({ status: 'loading' })
    load()
      .then((data) => {
        if (!cancelled) setState({ status: 'ready', data })
      })
      .catch((error: any) => {
        if (!cancelled) setState({ status: 'error', message: error?.message ?? 'Something went wrong.' })
      })
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)

  return state
}
