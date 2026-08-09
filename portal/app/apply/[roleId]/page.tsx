import type { Metadata } from 'next'
import { ApplyForm } from '@/components/candidate/apply-form'

export const metadata: Metadata = {
  title: 'Apply — CogniHire',
  description: 'Apply directly with your résumé — no external form.',
}

export default async function ApplyPage({
  params,
}: {
  params: Promise<{ roleId: string }>
}) {
  const { roleId } = await params

  return (
    <div>
      <p className="label-mono text-muted-foreground">Application</p>
      <h1 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
        Apply for this role
      </h1>
      <p className="mt-4 max-w-lg text-sm leading-relaxed text-muted-foreground">
        Submit your résumé and we&apos;ll email you an interview code right away.
      </p>
      <div className="mt-8">
        <ApplyForm roleId={roleId} />
      </div>
    </div>
  )
}
