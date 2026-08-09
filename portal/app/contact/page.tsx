import type { Metadata } from 'next'
import Link from 'next/link'
import { PageShell, Prose } from '@/components/site/page-shell'
import { Button } from '@/components/ui/button'

export const metadata: Metadata = {
  title: 'Contact — CogniHire',
  description: 'Talk to the CogniHire team about evidence-based hiring.',
}

export default function ContactPage() {
  return (
    <PageShell
      eyebrow="Contact"
      title="Talk to us."
      intro="Questions about evidence reports, reviewer workflows or candidate experience."
    >
      <Prose>
        <h2>Companies</h2>
        <p>
          If you want to see how evidence reports fit your hiring process, start
          with a company account and bring one open role.
        </p>
        <h2>Candidates</h2>
        <p>
          If your interview code is not working, ask the company that invited
          you to reissue it — codes are generated per candidate.
        </p>
      </Prose>

      <div className="mt-10 flex flex-col gap-3 sm:flex-row">
        <Button
          render={<Link href="/signup" />}
          className="h-11 rounded-full px-6 text-sm"
        >
          Create your company account
        </Button>
        <Button
          render={<Link href="/interview" />}
          variant="outline"
          className="h-11 rounded-full px-6 text-sm"
        >
          I have an interview code
        </Button>
      </div>
    </PageShell>
  )
}
