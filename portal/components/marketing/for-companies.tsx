import { ArrowRight } from 'lucide-react'
import { ButtonLink } from '@/components/ui/button-link'
import { Section } from '@/components/marketing/section'

const workflow = [
  { title: 'Create a role', note: 'Define what matters for the position.' },
  { title: 'Receive candidates', note: 'Applications arrive with claims parsed.' },
  { title: 'Generate interview code', note: 'One code per candidate.' },
  { title: 'Review interview evidence', note: 'Read the trail, decide yourself.' },
]

export function ForCompanies() {
  return (
    <Section
      id="for-companies"
      eyebrow="For companies"
      title="A workflow your team already recognises."
    >
      <div className="mt-12 grid gap-10 lg:grid-cols-[1.05fr_0.95fr] lg:items-end lg:gap-16">
        <ol className="flex flex-col">
          {workflow.map((step, index) => (
            <li
              key={step.title}
              className="flex items-baseline gap-5 border-t border-border py-5 last:border-b sm:gap-8"
            >
              <span className="label-mono w-6 shrink-0 text-muted-foreground">
                {String(index + 1).padStart(2, '0')}
              </span>
              <span className="flex flex-1 flex-col gap-1 sm:flex-row sm:items-baseline sm:justify-between sm:gap-8">
                <span className="text-base font-medium tracking-[-0.015em]">
                  {step.title}
                </span>
                <span className="text-sm text-muted-foreground sm:max-w-[18rem] sm:text-right">
                  {step.note}
                </span>
              </span>
            </li>
          ))}
        </ol>

        <div className="rounded-xl border border-border bg-card p-6 sm:p-8">
          <p className="label-mono text-muted-foreground">Company account</p>
          <p className="mt-4 text-base leading-relaxed text-pretty">
            Roles, candidates, interview codes and evidence reports live in one
            reviewer workspace.
          </p>
          <div className="mt-7 flex flex-col gap-3 sm:flex-row">
            <ButtonLink
              href="/signup"
              className="h-11 rounded-full px-5 text-sm"
            >
              Create your company account
              <ArrowRight data-icon="inline-end" className="size-4" />
            </ButtonLink>
            <ButtonLink
              href="/dashboard"
              variant="ghost"
              className="h-11 rounded-full px-4 text-sm text-muted-foreground hover:text-foreground"
            >
              View workspace
            </ButtonLink>
          </div>
        </div>
      </div>
    </Section>
  )
}
