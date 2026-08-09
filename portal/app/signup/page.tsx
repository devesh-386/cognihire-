import type { Metadata } from 'next'
import { AuthForm } from '@/components/auth/auth-form'
import { PageShell } from '@/components/site/page-shell'

export const metadata: Metadata = {
  title: 'Get started — CogniHire',
  description: 'Create a CogniHire company account for your hiring team.',
}

export default function SignupPage() {
  return (
    <PageShell
      eyebrow="Get started"
      title="Create your company account."
      intro="Set up roles, invite candidates and review interview evidence in one workspace."
    >
      <AuthForm mode="signup" />
    </PageShell>
  )
}
