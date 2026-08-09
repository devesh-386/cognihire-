import { Section } from '@/components/marketing/section'

const steps = [
  { title: 'Apply', body: 'Candidate submits a resume.' },
  { title: 'Understand', body: 'Claims are read and structured.' },
  { title: 'Interview', body: 'Questions follow those claims.' },
  { title: 'Review evidence', body: 'Reviewers read the trail.' },
]

export function HowItWorks() {
  return (
    <Section id="how-it-works" eyebrow="How it works" title="Four steps.">
      <ol className="mt-12 grid grid-cols-1 gap-y-10 sm:grid-cols-2 lg:grid-cols-4 lg:gap-x-8">
        {steps.map((step, index) => (
          <li key={step.title} className="relative pt-6">
            <span
              aria-hidden="true"
              className="absolute inset-x-0 top-0 h-px bg-border"
            />
            <span
              aria-hidden="true"
              className="absolute top-0 left-0 h-px w-8 bg-foreground"
            />
            <p className="label-mono text-muted-foreground">
              Step {index + 1}
            </p>
            <h3 className="mt-3 text-xl font-medium tracking-[-0.02em]">
              {step.title}
            </h3>
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
              {step.body}
            </p>
          </li>
        ))}
      </ol>
    </Section>
  )
}
