import { Section } from '@/components/marketing/section'

const pillars = [
  {
    title: 'Evidence-first',
    body: 'Every important conclusion should trace back to candidate-provided evidence.',
  },
  {
    title: 'Grounded AI',
    body: 'AI assists with understanding, questioning and analysis while respecting the information actually provided by the candidate.',
  },
  {
    title: 'Human decisions',
    body: 'CogniHire does not replace the hiring decision with an opaque score.',
  },
]

export function WhyCogniHire() {
  return (
    <Section
      id="product"
      eyebrow="Why CogniHire"
      title="Understanding, not ranking."
    >
      <div className="mt-12 grid gap-px overflow-hidden rounded-xl border border-border bg-border md:grid-cols-3">
        {pillars.map((pillar, index) => (
          <article
            key={pillar.title}
            className="group flex flex-col justify-between gap-10 bg-card p-6 transition-colors duration-300 hover:bg-accent/40 sm:p-8"
          >
            <p className="label-mono text-muted-foreground">
              {String(index + 1).padStart(2, '0')}
            </p>
            <div>
              <h3 className="text-lg font-medium tracking-[-0.02em]">
                {pillar.title}
              </h3>
              <p className="mt-3 text-sm leading-relaxed text-muted-foreground">
                {pillar.body}
              </p>
            </div>
          </article>
        ))}
      </div>
    </Section>
  )
}
