'use client'

import { useEffect, useState } from 'react'
import { CheckCircle2, ExternalLink, Loader2, TriangleAlert } from 'lucide-react'
import { WorkspaceBody, WorkspaceHeader } from '@/components/app/app-shell'
import { Button } from '@/components/ui/button'
import { connectGoogle, getSession, googleStatus } from '@/lib/gateway'
import { useWorkspaceQuery } from '@/lib/use-workspace-query'

async function loadStatus() {
  const session = getSession()
  if (!session) throw new Error('not signed in')
  return googleStatus(session.organizationId)
}

export default function SettingsPage() {
  const state = useWorkspaceQuery(loadStatus, [])
  const [connecting, setConnecting] = useState(false)
  const [connectError, setConnectError] = useState<string | null>(null)
  // Read straight off window rather than useSearchParams — same reasoning
  // as components/auth/auth-form.tsx: avoids opting this page into dynamic
  // rendering / a Suspense boundary just to read one flag set by the
  // /google/oauth/callback redirect.
  const [justConnected, setJustConnected] = useState(false)

  useEffect(() => {
    setJustConnected(new URLSearchParams(window.location.search).has('google'))
  }, [])

  async function handleConnect() {
    const session = getSession()
    if (!session) return
    setConnecting(true)
    setConnectError(null)
    try {
      const { authorize_url: authorizeUrl } = await connectGoogle(session.organizationId)
      window.location.href = authorizeUrl
    } catch (err: any) {
      setConnecting(false)
      setConnectError(err?.message ?? 'Could not start the Google connection.')
    }
  }

  return (
    <>
      <WorkspaceHeader
        title="Settings"
        description="Connect your organization's Google account to create and manage application forms automatically."
      />
      <WorkspaceBody>
        <div className="max-w-xl bg-card p-6">
          <h2 className="text-sm font-medium tracking-[-0.01em]">Google Forms</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Connecting lets CogniHire create an application form for each intake automatically —
            forms live in your own organization&apos;s Google account, never a shared one.
          </p>

          {justConnected ? (
            <p
              role="status"
              className="mt-4 flex items-center gap-2 rounded-lg border border-border bg-muted px-4 py-3 text-xs text-muted-foreground"
            >
              <CheckCircle2 className="size-4 shrink-0 text-emerald-600" aria-hidden="true" />
              Redirected back from Google — checking connection status below.
            </p>
          ) : null}

          <div className="mt-5">
            {state.status === 'loading' ? (
              <p className="flex items-center gap-2 text-sm text-muted-foreground">
                <Loader2 className="size-4 animate-spin" aria-hidden="true" />
                Checking connection status…
              </p>
            ) : state.status === 'error' ? (
              <p className="flex items-center gap-2 text-sm text-destructive">
                <TriangleAlert className="size-4 shrink-0" aria-hidden="true" />
                {state.message}
              </p>
            ) : state.data.connected ? (
              <p className="flex items-center gap-2 text-sm">
                <CheckCircle2 className="size-4 shrink-0 text-emerald-600" aria-hidden="true" />
                Connected as{' '}
                <span className="font-medium">{state.data.google_account_email}</span>
              </p>
            ) : (
              <Button onClick={handleConnect} disabled={connecting} className="gap-2">
                {connecting ? (
                  <Loader2 className="size-4 animate-spin" aria-hidden="true" />
                ) : (
                  <ExternalLink className="size-4" aria-hidden="true" />
                )}
                Connect Google
              </Button>
            )}
            {connectError ? (
              <p className="mt-3 flex items-center gap-2 text-sm text-destructive">
                <TriangleAlert className="size-4 shrink-0" aria-hidden="true" />
                {connectError}
              </p>
            ) : null}
          </div>
        </div>
      </WorkspaceBody>
    </>
  )
}
