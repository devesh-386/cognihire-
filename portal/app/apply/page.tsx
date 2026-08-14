import type { Metadata } from 'next'
import { OpenRolesList } from '@/components/candidate/open-roles-list'

export const metadata: Metadata = {
  title: 'Apply — CogniHire',
  description: 'Browse open roles and apply directly — résumé upload, no external form.',
}

export default function ApplyGatePage() {
  return (
    <div>
      <p className="label-mono text-muted-foreground">Application</p>
      <h1 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
        Open roles
      </h1>
      <p className="mt-4 max-w-lg text-sm leading-relaxed text-muted-foreground">
        Pick a role to apply — you&apos;ll upload your résumé directly here. Your
        interview code arrives by email once it&apos;s ready.
      </p>
      <OpenRolesList className="mt-8 max-w-lg" />
    </div>
  )
}
