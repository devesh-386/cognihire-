import type { Metadata } from 'next'
import { OpenRolesList } from '@/components/candidate/open-roles-list'

export const metadata: Metadata = {
  title: 'Apply — CogniHire',
  description: 'Browse open roles and apply — each role opens its own application form.',
}

export default function ApplyGatePage() {
  return (
    <div>
      <p className="label-mono text-muted-foreground">Application</p>
      <h1 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
        Open roles
      </h1>
      <p className="mt-4 max-w-lg text-sm leading-relaxed text-muted-foreground">
        Pick a role to open its application form. Your interview code arrives
        by email once your résumé has been processed.
      </p>
      <OpenRolesList className="mt-8 max-w-lg" />
    </div>
  )
}
