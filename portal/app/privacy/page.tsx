import type { Metadata } from 'next'
import { PageShell, Prose } from '@/components/site/page-shell'

export const metadata: Metadata = {
  title: 'Privacy — CogniHire',
  description: 'How CogniHire handles candidate and company information.',
}

export default function PrivacyPage() {
  return (
    <PageShell
      eyebrow="Privacy"
      title="Privacy."
      intro="A summary of our approach. This page is a placeholder for the reviewed legal text."
    >
      <Prose>
        <h2>Candidate information</h2>
        <p>
          Candidates provide their application and their interview answers.
          Evidence is drawn from that material and nothing else.
        </p>
        <h2>Purpose limitation</h2>
        <p>
          Information submitted for a role is used to review that application.
          It is not used to build cross-company candidate profiles.
        </p>
        <h2>Access</h2>
        <p>
          Reviewers at the hiring company see the evidence report for the roles
          they are working on.
        </p>
      </Prose>
    </PageShell>
  )
}
