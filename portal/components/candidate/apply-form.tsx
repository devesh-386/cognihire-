'use client'

import { useEffect, useState } from 'react'
import { Check, Loader2, TriangleAlert, Upload } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { applyToRole, getRoleApplyInfo } from '@/lib/gateway'

type InfoStatus = 'loading' | 'ready' | 'error'
type SubmitStatus = 'idle' | 'submitting' | 'done' | 'error'

function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => {
      // reader.result is "data:<mime>;base64,<data>" — the gateway only
      // wants the payload after the comma.
      const result = String(reader.result ?? '')
      resolve(result.slice(result.indexOf(',') + 1))
    }
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(file)
  })
}

export function ApplyForm({ roleId }: { roleId: string }) {
  const [infoStatus, setInfoStatus] = useState<InfoStatus>('loading')
  const [roleTitle, setRoleTitle] = useState('')
  const [organizationName, setOrganizationName] = useState('')

  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [resumeFile, setResumeFile] = useState<File | null>(null)
  const [submitStatus, setSubmitStatus] = useState<SubmitStatus>('idle')
  const [message, setMessage] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    getRoleApplyInfo(roleId)
      .then((info: any) => {
        if (cancelled) return
        setRoleTitle(info.role_title)
        setOrganizationName(info.organization_name)
        setInfoStatus('ready')
      })
      .catch((error: any) => {
        if (cancelled) return
        setMessage(error?.message || 'That application link is no longer valid.')
        setInfoStatus('error')
      })
    return () => {
      cancelled = true
    }
  }, [roleId])

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!resumeFile) {
      setMessage('Attach your résumé (PDF) to apply.')
      setSubmitStatus('error')
      return
    }
    setSubmitStatus('submitting')
    setMessage(null)
    try {
      const resumeBase64 = await fileToBase64(resumeFile)
      const result: any = await applyToRole({
        roleId,
        name: name.trim(),
        email: email.trim(),
        resumeBase64,
      })
      setSubmitStatus('done')
      setMessage(
        `You're in — your interview code is ${result.code}. We've also emailed it to ${email.trim()}.`,
      )
    } catch (error: any) {
      setSubmitStatus('error')
      setMessage(error?.message || "We couldn't submit your application just now. Please try again.")
    }
  }

  if (infoStatus === 'loading') {
    return (
      <div className="flex items-center gap-2.5 text-sm text-muted-foreground">
        <Loader2 aria-hidden="true" className="size-4 animate-spin" />
        Loading…
      </div>
    )
  }

  if (infoStatus === 'error') {
    return (
      <p role="alert" className="flex gap-2.5 rounded-lg border border-border bg-muted px-4 py-3 text-sm text-muted-foreground">
        <TriangleAlert aria-hidden="true" className="mt-px size-4 shrink-0" />
        <span>{message}</span>
      </p>
    )
  }

  if (submitStatus === 'done') {
    return (
      <p className="flex gap-2.5 rounded-lg border border-border bg-card px-4 py-3 text-sm text-foreground">
        <Check aria-hidden="true" className="mt-px size-4 shrink-0" />
        <span>{message}</span>
      </p>
    )
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <p className="text-sm text-muted-foreground">
        Applying for <span className="font-medium text-foreground">{roleTitle}</span>
        {organizationName ? (
          <>
            {' '}at <span className="font-medium text-foreground">{organizationName}</span>
          </>
        ) : null}
      </p>

      <div className="flex flex-col gap-1.5">
        <label htmlFor="apply-name" className="text-xs font-medium text-muted-foreground">
          Full name
        </label>
        <input
          id="apply-name"
          required
          value={name}
          onChange={(event) => setName(event.target.value)}
          className="h-11 rounded-lg border border-input bg-background px-4 text-sm outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/25"
        />
      </div>

      <div className="flex flex-col gap-1.5">
        <label htmlFor="apply-email" className="text-xs font-medium text-muted-foreground">
          Email
        </label>
        <input
          id="apply-email"
          type="email"
          required
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          className="h-11 rounded-lg border border-input bg-background px-4 text-sm outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/25"
        />
      </div>

      <div className="flex flex-col gap-1.5">
        <label htmlFor="apply-resume" className="text-xs font-medium text-muted-foreground">
          Résumé (PDF)
        </label>
        <label
          htmlFor="apply-resume"
          className="flex h-11 cursor-pointer items-center gap-2 rounded-lg border border-dashed border-input bg-background px-4 text-sm text-muted-foreground transition-colors hover:bg-accent/40"
        >
          <Upload aria-hidden="true" className="size-4" />
          {resumeFile ? resumeFile.name : 'Choose a file…'}
        </label>
        <input
          id="apply-resume"
          type="file"
          accept="application/pdf"
          required
          className="sr-only"
          onChange={(event) => setResumeFile(event.target.files?.[0] ?? null)}
        />
      </div>

      {submitStatus === 'error' && message ? (
        <p role="alert" className="text-xs text-destructive">
          {message}
        </p>
      ) : null}

      <Button type="submit" disabled={submitStatus === 'submitting'} className="h-11 rounded-full text-sm">
        {submitStatus === 'submitting' ? (
          <Loader2 aria-hidden="true" className="size-4 animate-spin" />
        ) : (
          'Submit application'
        )}
      </Button>
    </form>
  )
}
