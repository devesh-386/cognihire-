import { ButtonLink } from '@/components/ui/button-link'

export function CompanyCta() {
  return (
    <section className="border-b border-border">
      <div className="mx-auto w-full max-w-6xl px-5 py-20 lg:px-8 lg:py-28">
        <div className="flex flex-col items-start gap-10 lg:flex-row lg:items-end lg:justify-between">
          <h2 className="max-w-2xl text-3xl leading-[1.08] font-medium tracking-[-0.035em] text-balance sm:text-5xl">
            Make hiring decisions with evidence, not opaque scores.
          </h2>
          <div className="flex shrink-0 flex-col gap-3 sm:flex-row">
            <ButtonLink
              href="/signup"
              className="h-11 rounded-full px-6 text-sm"
            >
              Get Started
            </ButtonLink>
            <ButtonLink
              href="/login"
              variant="outline"
              className="h-11 rounded-full px-6 text-sm"
            >
              Sign In
            </ButtonLink>
          </div>
        </div>
      </div>
    </section>
  )
}
