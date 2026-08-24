import type { Metadata } from 'next'
import Link from 'next/link'
import { Check } from 'lucide-react'
import { Button } from '@/components/ui/button'

export const metadata: Metadata = {
  title: 'Interview complete — CogniHire',
  description: 'Your interview has been submitted for review.',
}

const notes = [
  'Your answers are kept with the claims they respond to.',
  'A reviewer reads the evidence trail, not a score.',
  'The hiring decision is made by people at the company.',
]

export default async function InterviewCompletePage({
  searchParams,
}: {
  // Next 15: searchParams reaches a server component as a Promise.
  searchParams: Promise<{ session?: string }>
}) {
  const sessionId = (await searchParams).session

  return (
    <div className="max-w-xl">
      <span className="inline-flex size-9 items-center justify-center rounded-full border border-border bg-card">
        <Check aria-hidden="true" className="size-4" />
      </span>
      <h1 className="mt-6 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
        Interview complete.
      </h1>
      <p className="mt-4 text-sm leading-relaxed text-muted-foreground">
        Thank you — you can close this tab. Nothing else is required from you.
      </p>
      {sessionId ? (
        <p className="label-mono mt-3 text-muted-foreground">
          Session {sessionId}
        </p>
      ) : null}

      <ul className="mt-8 flex flex-col gap-px overflow-hidden rounded-xl border border-border bg-border">
        {notes.map((note) => (
          <li
            key={note}
            className="bg-card px-5 py-4 text-sm leading-relaxed text-muted-foreground"
          >
            {note}
          </li>
        ))}
      </ul>

      <div className="mt-8">
        <Button
          render={<Link href="/" />}
          variant="outline"
          className="h-11 rounded-full px-5 text-sm"
        >
          Learn about CogniHire
        </Button>
      </div>
    </div>
  )
}
