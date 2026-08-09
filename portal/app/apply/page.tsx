import type { Metadata } from 'next'
import Link from 'next/link'
import { ArrowRight } from 'lucide-react'
import { listOpenRoles } from '@/lib/gateway'

// Roles are created/removed continuously by HR — a build-time snapshot would
// hide new openings until the next deploy.
export const dynamic = 'force-dynamic'

export const metadata: Metadata = {
  title: 'Open roles — CogniHire',
  description: 'Pick a role to apply — submit your résumé and get an interview code right away.',
}

export default async function OpenRolesPage() {
  let roles: { id: string; title: string; organization_name: string }[] = []
  let error: string | null = null

  try {
    const result: any = await listOpenRoles()
    roles = result.roles ?? []
  } catch (e: any) {
    error = e?.message || "We couldn't load open roles right now."
  }

  return (
    <div>
      <p className="label-mono text-muted-foreground">Open roles</p>
      <h1 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
        Pick a role to apply
      </h1>
      <p className="mt-4 max-w-lg text-sm leading-relaxed text-muted-foreground">
        Submit your résumé and we&apos;ll email you an interview code right away.
      </p>

      {error ? (
        <p role="alert" className="mt-8 rounded-lg border border-border bg-muted px-4 py-3 text-sm text-muted-foreground">
          {error}
        </p>
      ) : roles.length === 0 ? (
        <p className="mt-8 rounded-lg border border-border bg-muted px-4 py-3 text-sm text-muted-foreground">
          There are no open roles right now. Check back soon.
        </p>
      ) : (
        <ul className="mt-8 flex flex-col gap-px overflow-hidden rounded-lg border border-border bg-border">
          {roles.map((role) => (
            <li key={role.id} className="bg-card">
              <Link
                href={`/apply/${role.id}`}
                className="flex items-center justify-between gap-4 px-5 py-4 transition-colors hover:bg-accent/40"
              >
                <span>
                  <span className="block text-sm font-medium text-foreground">{role.title}</span>
                  {role.organization_name ? (
                    <span className="block text-xs text-muted-foreground">{role.organization_name}</span>
                  ) : null}
                </span>
                <ArrowRight aria-hidden="true" className="size-4 shrink-0 text-muted-foreground" />
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
