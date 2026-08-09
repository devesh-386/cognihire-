'use client'

import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useEffect, useState } from 'react'
import { TriangleAlert } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { login, signup } from '@/lib/gateway'

type Mode = 'login' | 'signup'

const fieldClass =
  'h-11 w-full rounded-lg border border-input bg-background px-3.5 text-sm outline-none transition-colors placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/25'

export function AuthForm({ mode }: { mode: Mode }) {
  const router = useRouter()
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [expired, setExpired] = useState(false)

  // Read straight off `window` rather than via `useSearchParams`: this page
  // is statically prerendered, and `useSearchParams` would either opt it into
  // dynamic rendering or require a Suspense boundary around the whole form.
  // The flag is set by gateway.js when a request 401s mid-session.
  useEffect(() => {
    if (mode !== 'login') return
    setExpired(new URLSearchParams(window.location.search).has('expired'))
  }, [mode])

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError(null)
    setPending(true)

    const form = new FormData(event.currentTarget)
    const email = String(form.get('email') ?? '')
    const password = String(form.get('password') ?? '')

    try {
      if (mode === 'signup') {
        const organizationName = String(form.get('company') ?? '')
        const name = String(form.get('name') ?? '')
        await signup({ organizationName, name, email, password })
      } else {
        await login({ email, password })
      }
      router.push('/dashboard')
    } catch (err: any) {
      setPending(false)
      setError(err?.message ?? 'Something went wrong. Please try again.')
    }
  }

  return (
    <div className="rounded-xl border border-border bg-card p-6 sm:p-8">
      {expired ? (
        <p
          role="status"
          className="mb-5 flex gap-2.5 rounded-lg border border-border bg-muted px-4 py-3 text-xs leading-relaxed text-muted-foreground"
        >
          <TriangleAlert aria-hidden="true" className="mt-px size-4 shrink-0" />
          <span>Your session expired. Sign in again to pick up where you left off.</span>
        </p>
      ) : null}

      <form onSubmit={handleSubmit} className="flex flex-col gap-5">
        {mode === 'signup' ? (
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Company name" name="company" placeholder="Acme Inc." />
            <Field label="Your name" name="name" placeholder="Alex Moreau" />
          </div>
        ) : null}

        <Field
          label="Work email"
          name="email"
          type="email"
          placeholder="you@company.com"
        />
        <Field
          label="Password"
          name="password"
          type="password"
          placeholder="••••••••••"
          hint={mode === 'signup' ? 'At least 12 characters.' : undefined}
        />

        <Button
          type="submit"
          disabled={pending}
          className="mt-1 h-11 w-full rounded-full text-sm"
        >
          {pending
            ? 'Please wait…'
            : mode === 'signup'
              ? 'Create company account'
              : 'Sign in'}
        </Button>
      </form>

      {error ? (
        <p
          role="alert"
          className="mt-5 flex gap-2.5 rounded-lg border border-border bg-muted px-4 py-3 text-xs leading-relaxed text-muted-foreground"
        >
          <TriangleAlert aria-hidden="true" className="mt-px size-4 shrink-0" />
          <span>{error}</span>
        </p>
      ) : null}

      <p className="mt-6 border-t border-border pt-5 text-sm text-muted-foreground">
        {mode === 'signup' ? (
          <>
            Already have an account?{' '}
            <Link
              href="/login"
              className="font-medium text-foreground underline-offset-4 hover:underline"
            >
              Sign in
            </Link>
          </>
        ) : (
          <>
            Need a company account?{' '}
            <Link
              href="/signup"
              className="font-medium text-foreground underline-offset-4 hover:underline"
            >
              Get started
            </Link>
          </>
        )}
      </p>
    </div>
  )
}

function Field({
  label,
  name,
  type = 'text',
  placeholder,
  hint,
}: {
  label: string
  name: string
  type?: string
  placeholder?: string
  hint?: string
}) {
  return (
    <div className="flex flex-col gap-2">
      <label htmlFor={name} className="text-xs font-medium">
        {label}
      </label>
      <input
        id={name}
        name={name}
        type={type}
        placeholder={placeholder}
        autoComplete={
          type === 'password'
            ? 'current-password'
            : name === 'email'
              ? 'email'
              : 'off'
        }
        className={fieldClass}
      />
      {hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}
    </div>
  )
}
