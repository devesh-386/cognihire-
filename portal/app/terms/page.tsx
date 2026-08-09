import type { Metadata } from 'next'
import { PageShell, Prose } from '@/components/site/page-shell'

export const metadata: Metadata = {
  title: 'Terms — CogniHire',
  description: 'The terms under which CogniHire is provided.',
}

export default function TermsPage() {
  return (
    <PageShell
      eyebrow="Terms"
      title="Terms."
      intro="A summary of our approach. This page is a placeholder for the reviewed legal text."
    >
      <Prose>
        <h2>Decision responsibility</h2>
        <p>
          CogniHire produces evidence for review. The hiring company remains
          responsible for every hiring decision it makes.
        </p>
        <h2>Acceptable use</h2>
        <p>
          Evidence reports are for evaluating applications to a specific role.
        </p>
        <h2>Service scope</h2>
        <p>
          CogniHire does not guarantee outcomes, rankings, or the accuracy of
          statements made by candidates.
        </p>
      </Prose>
    </PageShell>
  )
}
