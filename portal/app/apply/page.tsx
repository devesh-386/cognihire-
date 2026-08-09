import type { Metadata } from 'next'
import { GoogleFormGate } from '@/components/candidate/google-form-gate'

export const metadata: Metadata = {
  title: 'Apply — CogniHire',
  description: 'Start your application — résumé, role, and interview time all live on the application form.',
}

export default function ApplyGatePage() {
  return (
    <div>
      <p className="label-mono text-muted-foreground">Application</p>
      <h1 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
        Start your application
      </h1>
      <p className="mt-4 max-w-lg text-sm leading-relaxed text-muted-foreground">
        Enter your email to continue to the application form, where you&apos;ll
        pick a role, upload your résumé, and choose an interview time.
      </p>
      <GoogleFormGate className="mt-8 max-w-lg" />
    </div>
  )
}
