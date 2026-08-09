import type { Metadata } from 'next'
import { AuthForm } from '@/components/auth/auth-form'
import { PageShell } from '@/components/site/page-shell'

export const metadata: Metadata = {
  title: 'Sign in — CogniHire',
  description: 'Sign in to your CogniHire reviewer workspace.',
}

export default function LoginPage() {
  return (
    <PageShell
      eyebrow="Company access"
      title="Sign in."
      intro="Return to your roles, candidates and evidence reports."
    >
      <AuthForm mode="login" />
    </PageShell>
  )
}
