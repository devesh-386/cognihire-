import { Camera, Globe, Mic } from 'lucide-react'
import { InterviewCodeForm } from '@/components/candidate/interview-code-form'
import { GoogleFormGate } from '@/components/candidate/google-form-gate'

const checks = [
  { icon: Globe, label: 'Browser only' },
  { icon: Camera, label: 'Camera check' },
  { icon: Mic, label: 'Microphone check' },
]

export function ForCandidates() {
  return (
    <section id="for-candidates" className="scroll-mt-16 border-b border-border">
      <div className="mx-auto w-full max-w-6xl px-5 py-16 lg:px-8 lg:py-24">
        <div className="grid gap-10 rounded-xl border border-border bg-card p-6 sm:p-10 lg:grid-cols-[1fr_0.85fr] lg:items-center lg:gap-16 lg:p-12">
          <div>
            <p className="label-mono text-muted-foreground">For candidates</p>

            <h2 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] text-balance sm:text-4xl">
              New here? Start with your email.
            </h2>
            <p className="mt-4 max-w-md text-sm leading-relaxed text-muted-foreground">
              Enter your email and we&apos;ll take you to the application form —
              pick a role, upload your résumé, and choose your interview time
              there. Your interview code arrives by email, never shown here.
            </p>
            <GoogleFormGate className="mt-6 max-w-lg" />

            <h2 className="mt-10 text-3xl leading-[1.1] font-medium tracking-[-0.03em] text-balance sm:text-4xl">
              Have an interview code?
            </h2>
            <p className="mt-4 max-w-md text-sm leading-relaxed text-muted-foreground">
              You can complete the interview from your browser. We&apos;ll check
              camera and microphone permissions before anything starts, and your
              answers are what the evidence is built from.
            </p>
            <InterviewCodeForm className="mt-8 max-w-lg" />
          </div>

          <ul className="flex flex-col gap-px overflow-hidden rounded-lg border border-border bg-border">
            {checks.map((check) => (
              <li
                key={check.label}
                className="flex items-center gap-3 bg-card px-5 py-4"
              >
                <check.icon
                  aria-hidden="true"
                  className="size-4 text-muted-foreground"
                />
                <span className="text-sm">{check.label}</span>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </section>
  )
}
