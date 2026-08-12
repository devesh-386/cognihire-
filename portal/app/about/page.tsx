import type { Metadata } from 'next'
import { PageShell, Prose } from '@/components/site/page-shell'

export const metadata: Metadata = {
  title: 'About — CogniHire',
  description:
    'CogniHire exists to make interview conclusions traceable to candidate evidence.',
}

export default function AboutPage() {
  return (
    <PageShell
      eyebrow="About"
      title="Evidence over opaque scores."
      intro="CogniHire produces an audited record of what candidates actually demonstrated — every claim sealed as verified, disputed, unmeasured, or not examined — while keeping final decisions with humans."
    >
      <Prose>
        <h2>Why we build this way</h2>
        <p>
          Hiring tools tend to compress a person into a number. A number hides
          its own reasoning, so nobody can argue with it or learn from it.
          CogniHire takes the opposite position: if a conclusion matters, it
          should point at the candidate&apos;s own words.
        </p>

        <h2>What the AI does</h2>
        <p>
          It reads claims, forms questions that follow from them, and extracts
          the passages of an answer that support or contradict a claim. It works
          only with what the candidate provided.
        </p>

        <h2>What the AI does not do</h2>
        <p>
          It does not rank candidates, produce an overall score, or make the
          hiring decision. <strong>People decide.</strong>
        </p>
      </Prose>
    </PageShell>
  )
}
