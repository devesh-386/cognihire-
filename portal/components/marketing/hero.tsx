import { ButtonLink } from '@/components/ui/button-link'
import { EvidenceFlow } from '@/components/marketing/evidence-flow'

export function Hero() {
  return (
    <section className="relative overflow-hidden border-b border-border">
      <div
        aria-hidden="true"
        className="hairline-grid pointer-events-none absolute inset-0 opacity-[0.5] [mask-image:radial-gradient(120%_80%_at_50%_0%,black,transparent_75%)]"
      />
      <div className="relative mx-auto w-full max-w-6xl px-5 pt-16 pb-16 lg:px-8 lg:pt-24 lg:pb-24">
        <div className="max-w-3xl">
          <p className="rise label-mono text-muted-foreground">
            Evidence over opaque scores
          </p>
          <h1 className="rise mt-6 text-[2.5rem] leading-[1.05] font-medium tracking-[-0.035em] text-balance sm:text-6xl lg:text-[4.25rem]">
            See the evidence behind{' '}
            <span className="relative inline-block">
              <span className="relative z-10">every interview</span>
              <span
                aria-hidden="true"
                className="absolute inset-x-0 bottom-[0.1em] z-0 h-[0.32em] bg-evidence/70"
              />
            </span>
            .
          </h1>
          <p className="rise mt-7 max-w-xl text-base leading-relaxed text-muted-foreground sm:text-lg">
            CogniHire turns candidate claims and interview conversations into
            grounded evidence that hiring teams can review.
          </p>

          <div className="rise mt-9 flex flex-col gap-3 sm:flex-row sm:items-center">
            <ButtonLink
              href="/signup"
              className="h-11 rounded-full px-6 text-sm"
            >
              Get Started
            </ButtonLink>
            <ButtonLink
              href="/#how-it-works"
              variant="outline"
              className="h-11 rounded-full px-6 text-sm"
            >
              See How It Works
            </ButtonLink>
          </div>
        </div>

        <div className="rise mt-14 lg:mt-20" style={{ animationDelay: '160ms' }}>
          <EvidenceFlow />
        </div>
      </div>
    </section>
  )
}
