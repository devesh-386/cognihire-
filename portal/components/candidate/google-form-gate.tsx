'use client'

import { useState } from 'react'
import { ArrowRight } from 'lucide-react'
import { Button } from '@/components/ui/button'

// The Google Form is the only place a candidate uploads a resume or picks a
// preferred interview slot — see infra/google-form-apps-script.gs for what
// it forwards to intake-webhook. This component's only job is the gate in
// front of it: collect the email that pre-fills the form's own email
// question, then hand off. Nothing about the application (resume, role,
// timing) is ever collected or shown on this site — the code is emailed
// once the AI pipeline finishes, never displayed here.
const GOOGLE_FORM_URL = process.env.NEXT_PUBLIC_GOOGLE_FORM_URL
// Set via Google Forms' own "Get pre-filled link" tool against the form's
// "Email" question, then copy just the entry.<id> parameter name here.
const GOOGLE_FORM_EMAIL_ENTRY = process.env.NEXT_PUBLIC_GOOGLE_FORM_EMAIL_ENTRY

export function GoogleFormGate({ className }: { className?: string }) {
  const [email, setEmail] = useState('')
  const [touched, setTouched] = useState(false)

  const emailIsValid = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setTouched(true)
    if (!emailIsValid || !GOOGLE_FORM_URL) return

    const url = new URL(GOOGLE_FORM_URL)
    if (GOOGLE_FORM_EMAIL_ENTRY) {
      url.searchParams.set(GOOGLE_FORM_EMAIL_ENTRY, email.trim())
    }
    window.location.href = url.toString()
  }

  if (!GOOGLE_FORM_URL) {
    return (
      <p className={className}>
        <span className="block rounded-lg border border-border bg-muted px-4 py-3 text-sm text-muted-foreground">
          Applications aren&apos;t open yet — check back soon.
        </span>
      </p>
    )
  }

  return (
    <form onSubmit={handleSubmit} className={className}>
      <div className="flex flex-col gap-1.5 sm:flex-row sm:gap-2">
        <label htmlFor="candidate-gate-email" className="sr-only">
          Your email
        </label>
        <input
          id="candidate-gate-email"
          type="email"
          required
          placeholder="you@example.com"
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          onBlur={() => setTouched(true)}
          className="h-11 flex-1 rounded-lg border border-input bg-background px-4 text-sm outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/25"
        />
        <Button type="submit" className="h-11 shrink-0 rounded-full px-5 text-sm">
          Continue to application
          <ArrowRight aria-hidden="true" className="size-4" />
        </Button>
      </div>
      {touched && !emailIsValid ? (
        <p role="alert" className="mt-2 text-xs text-destructive">
          Enter a valid email to continue.
        </p>
      ) : (
        <p className="mt-2 text-xs text-muted-foreground">
          You&apos;ll pick your role, upload your résumé, and choose your interview
          time on the next page. Your interview code arrives by email once
          it&apos;s ready — never shown on screen.
        </p>
      )}
    </form>
  )
}
