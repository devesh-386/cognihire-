import { Check, CornerDownRight } from 'lucide-react'

export function EvidenceReport() {
  return (
    <section
      id="evidence"
      className="border-b border-border bg-ink text-ink-foreground"
    >
      <div className="mx-auto w-full max-w-6xl px-5 py-16 lg:px-8 lg:py-24">
        <header className="max-w-2xl">
          <p className="label-mono text-ink-foreground/55">Evidence report</p>
          <h2 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] text-balance sm:text-4xl">
            Every conclusion keeps its receipts.
          </h2>
          <p className="mt-4 text-base leading-relaxed text-ink-foreground/60 text-pretty">
            A claim, the question it prompted, the answer it received, and the
            exact line that supports it.
          </p>
        </header>

        <div className="mt-12 grid gap-px overflow-hidden rounded-xl border border-ink-foreground/12 bg-ink-foreground/12 lg:grid-cols-[0.85fr_1.15fr]">
          {/* Claim + question */}
          <div className="flex flex-col gap-8 bg-ink p-6 sm:p-8">
            <div>
              <p className="label-mono text-ink-foreground/55">
                Candidate claim
              </p>
              <p className="mt-3 text-lg leading-snug tracking-[-0.01em]">
                &ldquo;Built REST APIs using Python.&rdquo;
              </p>
              <p className="label-mono mt-3 text-ink-foreground/40">
                Source · Resume, line 14
              </p>
            </div>

            <div className="flex gap-3 border-t border-ink-foreground/12 pt-8">
              <CornerDownRight
                aria-hidden="true"
                className="mt-1 size-4 shrink-0 text-evidence"
              />
              <div>
                <p className="label-mono text-ink-foreground/55">
                  Interview question
                </p>
                <p className="mt-3 text-base leading-relaxed text-ink-foreground/90">
                  Explain how you designed authentication for one of your APIs.
                </p>
              </div>
            </div>
          </div>

          {/* Answer + evidence */}
          <div className="flex flex-col gap-8 bg-ink p-6 sm:p-8">
            <div>
              <p className="label-mono text-ink-foreground/55">
                Candidate response
              </p>
              <p className="mt-3 text-[0.9375rem] leading-relaxed text-ink-foreground/70">
                I used FastAPI with short-lived access tokens and refresh tokens
                kept in httpOnly cookies.{' '}
                <mark className="bg-evidence/25 px-0.5 text-ink-foreground decoration-evidence/70 underline-offset-4">
                  Tokens were signed with a rotating secret pulled from our
                  secrets manager, and every route declared an auth dependency,
                  so an expired token never reached a handler.
                </mark>{' '}
                We logged failures per client so we could see brute-force
                attempts early.
              </p>
            </div>

            <div className="border-t border-ink-foreground/12 pt-8">
              <p className="label-mono text-ink-foreground/55">
                Evidence extracted
              </p>
              <blockquote className="mt-3 border-l-2 border-evidence pl-4 text-[0.9375rem] leading-relaxed text-ink-foreground">
                &ldquo;Tokens were signed with a rotating secret pulled from our
                secrets manager, and every route declared an auth
                dependency.&rdquo;
              </blockquote>

              <dl className="mt-7 flex flex-wrap items-center gap-x-10 gap-y-5">
                <div>
                  <dt className="label-mono text-ink-foreground/55">Verdict</dt>
                  <dd className="mt-2 inline-flex items-center gap-1.5 rounded-full border border-evidence/40 bg-evidence/12 px-2.5 py-1 text-xs font-medium text-evidence">
                    <Check aria-hidden="true" className="size-3.5" />
                    Supported
                  </dd>
                </div>
                <div>
                  <dt className="label-mono text-ink-foreground/55">
                    Confidence
                  </dt>
                  <dd className="mt-2 flex items-center gap-2 text-xs font-medium">
                    <span aria-hidden="true" className="flex gap-1">
                      {[0, 1, 2].map((bar) => (
                        <span
                          key={bar}
                          className="block h-3 w-1.5 rounded-full bg-evidence"
                        />
                      ))}
                    </span>
                    High
                  </dd>
                </div>
              </dl>
            </div>
          </div>
        </div>

        <p className="label-mono mt-6 text-ink-foreground/40">
          Fictional example · No overall score, no ranking
        </p>
      </div>
    </section>
  )
}
