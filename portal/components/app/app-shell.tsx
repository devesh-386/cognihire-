'use client'

import Link from 'next/link'
import { usePathname, useRouter } from 'next/navigation'
import { useEffect, useState, type ReactNode } from 'react'
import {
  Briefcase,
  FileText,
  LayoutDashboard,
  LogOut,
  MessageSquare,
  Users,
} from 'lucide-react'
import { Logo } from '@/components/site/logo'
import { Button } from '@/components/ui/button'
import { ButtonLink } from '@/components/ui/button-link'
import { clearSession, getSession } from '@/lib/gateway'
import { cn } from '@/lib/utils'

const workspaceNav = [
  { label: 'Dashboard', href: '/dashboard', icon: LayoutDashboard },
  { label: 'Roles', href: '/roles', icon: Briefcase },
  { label: 'Candidates', href: '/candidates', icon: Users },
  { label: 'Interviews', href: '/interviews', icon: MessageSquare },
  { label: 'Reports', href: '/reports', icon: FileText },
]

export function AppShell({ children }: { children: ReactNode }) {
  const pathname = usePathname()
  const router = useRouter()
  const [email, setEmail] = useState<string | null>(null)

  useEffect(() => {
    const session = getSession()
    if (!session) {
      router.replace('/login')
      return
    }
    setEmail(session.email)
  }, [router])

  function signOut() {
    clearSession()
    router.replace('/login')
  }

  if (!email) return null

  return (
    <div className="min-h-svh lg:grid lg:grid-cols-[15rem_1fr]">
      <aside className="flex flex-col gap-6 border-b border-border bg-sidebar px-5 py-5 lg:sticky lg:top-0 lg:h-svh lg:border-r lg:border-b-0">
        <div className="flex items-center justify-between">
          <Logo />
          <ButtonLink
            href="/"
            variant="ghost"
            size="sm"
            className="text-muted-foreground hover:text-foreground lg:hidden"
          >
            Exit
          </ButtonLink>
        </div>

        <nav aria-label="Workspace" className="flex-1">
          <ul className="flex gap-1 overflow-x-auto lg:flex-col lg:overflow-visible">
            {workspaceNav.map((item) => {
              const active = pathname === item.href
              return (
                <li key={item.href} className="shrink-0">
                  <Link
                    href={item.href}
                    aria-current={active ? 'page' : undefined}
                    className={cn(
                      'flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm transition-colors',
                      active
                        ? 'bg-accent font-medium text-accent-foreground'
                        : 'text-muted-foreground hover:bg-muted hover:text-foreground',
                    )}
                  >
                    <item.icon aria-hidden="true" className="size-4" />
                    {item.label}
                  </Link>
                </li>
              )
            })}
          </ul>
        </nav>

        <div className="flex flex-col gap-2">
          <p className="truncate text-xs text-muted-foreground">{email}</p>
          <div className="hidden lg:block">
            <ButtonLink
              href="/"
              variant="outline"
              className="h-9 w-full rounded-lg text-xs"
            >
              Back to site
            </ButtonLink>
          </div>
          <Button
            onClick={signOut}
            variant="outline"
            className="h-9 w-full rounded-lg text-xs"
          >
            <LogOut aria-hidden="true" className="size-3.5" />
            Sign out
          </Button>
        </div>
      </aside>

      <div className="min-w-0">{children}</div>
    </div>
  )
}

export function WorkspaceHeader({
  title,
  description,
  action,
}: {
  title: string
  description?: string
  action?: ReactNode
}) {
  return (
    <header className="flex flex-col gap-4 border-b border-border px-5 py-8 lg:flex-row lg:items-end lg:justify-between lg:px-10 lg:py-10">
      <div>
        <p className="label-mono text-muted-foreground">Workspace</p>
        <h1 className="mt-3 text-2xl font-medium tracking-[-0.025em] sm:text-3xl">
          {title}
        </h1>
        {description ? (
          <p className="mt-2 max-w-xl text-sm leading-relaxed text-muted-foreground">
            {description}
          </p>
        ) : null}
      </div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </header>
  )
}

export function WorkspaceBody({ children }: { children: ReactNode }) {
  return <div className="px-5 py-8 lg:px-10 lg:py-10">{children}</div>
}

export function EmptyState({
  title,
  body,
  hint,
}: {
  title: string
  body: string
  hint?: string
}) {
  return (
    <div className="rounded-xl border border-dashed border-border bg-card px-6 py-14 text-center">
      <h2 className="text-base font-medium tracking-[-0.01em]">{title}</h2>
      <p className="mx-auto mt-2 max-w-md text-sm leading-relaxed text-muted-foreground">
        {body}
      </p>
      {hint ? (
        <p className="label-mono mt-6 text-muted-foreground">{hint}</p>
      ) : null}
    </div>
  )
}
