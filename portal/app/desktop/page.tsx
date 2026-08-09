import type { Metadata } from 'next'
import Link from 'next/link'
import { PageShell } from '@/components/site/page-shell'

export const metadata: Metadata = {
  title: 'The desktop app — CogniHire',
  description:
    'CogniHire runs in two places: a browser portal for typed, code-based interviews, and a desktop app that verifies identity continuously and interviews by voice.',
}

// The two surfaces, stated as capability differences rather than a feature
// grid with ticks. Every "no" here is deliberate and load-bearing — the
// browser genuinely cannot verify identity (there is no enrolled reference
// to compare a face against), and saying so is the same discipline the
// reports apply to an unsubstantiated claim.
const surfaces = [
  {
    name: 'Browser portal',
    tagline: 'Nothing to install. Open a link, answer questions.',
    where: 'This site, at /interview',
    points: [
      'Candidate opens an emailed interview code — no account, no download.',
      'Answers are typed. Questions adapt from the answer just given.',
      'Camera and microphone are checked before starting, so a dead mic is found up front rather than three questions in.',
      'Identity is not verified. There is no enrolled reference photo to compare against, so the portal does not claim a check it cannot perform.',
    ],
  },
  {
    name: 'Desktop app',
    tagline: 'A spoken interview, with identity re-checked throughout.',
    where: 'Installed on the interviewing machine',
    points: [
      'A reference face is enrolled before the session. A session cannot start without one.',
      'Identity is re-checked on a jittered interval for the whole session, not once at login.',
      'The interview is spoken. The model listens continuously, and the candidate can interrupt it mid-sentence.',
      'The language model runs locally. No API key, and the session works with no internet connection.',
    ],
  },
]

function SurfaceCard({ surface }: { surface: (typeof surfaces)[number] }) {
  return (
    <div className="flex flex-col gap-5 bg-card p-6 sm:p-7">
      <div>
        <h2 className="text-base font-medium tracking-[-0.01em]">
          {surface.name}
        </h2>
        <p className="mt-1.5 text-sm leading-relaxed text-muted-foreground">
          {surface.tagline}
        </p>
        <p className="label-mono mt-4 text-muted-foreground">{surface.where}</p>
      </div>
      <ul className="flex flex-col gap-3">
        {surface.points.map((point) => (
          <li
            key={point}
            className="text-sm leading-relaxed text-muted-foreground"
          >
            {point}
          </li>
        ))}
      </ul>
    </div>
  )
}

export default function DesktopPage() {
  return (
    <PageShell
      eyebrow="The desktop app"
      title="Two ways to run an interview."
      intro="Most candidates will never install anything — they open a link and type. The desktop app exists for the sessions where it matters who is actually answering."
    >
      <div className="flex flex-col gap-12">
        <div className="grid gap-px overflow-hidden rounded-xl border border-border bg-border sm:grid-cols-2">
          {surfaces.map((surface) => (
            <SurfaceCard key={surface.name} surface={surface} />
          ))}
        </div>

        <section className="flex flex-col gap-5 text-[0.9375rem] leading-relaxed text-muted-foreground">
          <h2 className="text-base font-medium tracking-[-0.01em] text-foreground">
            Why verification is a separate surface
          </h2>
          <p>
            Conventional proctoring checks identity once, at sign-in, and then
            watches the room. After that first check, a substitute sitting the
            interview is invisible. The desktop app re-checks{' '}
            <strong className="font-medium text-foreground">
              who is producing the work
            </strong>{' '}
            for the duration of the session.
          </p>
          <p>
            Checks that could not be performed — no face in frame, a closed
            camera, an unreachable service — are recorded as unmeasured. They
            are never recorded as passes, and the report says how much of the
            session was actually covered.
          </p>

          <h2 className="mt-2 text-base font-medium tracking-[-0.01em] text-foreground">
            What both surfaces share
          </h2>
          <p>
            The same claim pipeline runs underneath either one. Claims are
            extracted from the résumé and must appear verbatim in it to survive.
            Questions are planned against those claims. Evidence is quoted from
            the candidate&apos;s own answer. Neither surface produces a score,
            and neither makes a hiring decision.
          </p>
          <p>
            Sessions from both land in the same place —{' '}
            <Link
              href="/reports"
              className="text-foreground underline underline-offset-4 hover:opacity-70"
            >
              Reports
            </Link>{' '}
            — as one row per claim, with the question that was asked and the
            answer that did or did not substantiate it.
          </p>
        </section>
      </div>
    </PageShell>
  )
}
