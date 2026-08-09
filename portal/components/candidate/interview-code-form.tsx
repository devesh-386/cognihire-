'use client'

import { useRouter } from 'next/navigation'
import { useId, useState } from 'react'
import { ArrowRight } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

export function InterviewCodeForm({
  className,
  autoFocus = false,
}: {
  className?: string
  autoFocus?: boolean
}) {
  const router = useRouter()
  const inputId = useId()
  const [code, setCode] = useState('')
  const [error, setError] = useState<string | null>(null)

  const normalized = code.trim().toUpperCase()

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (normalized.length < 6) {
      setError('Interview codes are at least 6 characters.')
      return
    }
    setError(null)
    router.push(`/interview?code=${encodeURIComponent(normalized)}`)
  }

  return (
    <form onSubmit={handleSubmit} className={cn('flex flex-col gap-3', className)}>
      <label htmlFor={inputId} className="sr-only">
        Enter your interview code
      </label>
      <div className="flex flex-col gap-3 sm:flex-row">
        <input
          id={inputId}
          name="code"
          value={code}
          autoFocus={autoFocus}
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => {
            setCode(event.target.value)
            if (error) setError(null)
          }}
          placeholder="Enter your interview code"
          aria-invalid={error ? true : undefined}
          aria-describedby={error ? `${inputId}-error` : undefined}
          className="h-12 flex-1 rounded-full border border-input bg-background px-5 font-mono text-sm tracking-[0.12em] uppercase outline-none transition-colors placeholder:font-sans placeholder:tracking-normal placeholder:normal-case placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/25 aria-invalid:border-destructive"
        />
        <Button type="submit" className="h-12 rounded-full px-6 text-sm">
          Start Interview
          <ArrowRight data-icon="inline-end" className="size-4" />
        </Button>
      </div>
      {error ? (
        <p id={`${inputId}-error`} role="alert" className="text-xs text-destructive">
          {error}
        </p>
      ) : null}
    </form>
  )
}
