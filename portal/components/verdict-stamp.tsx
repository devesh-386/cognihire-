import { cn } from '@/lib/utils'

export type VerdictKind =
  | 'verified'
  | 'disputed'
  | 'unmeasured'
  | 'not-examined'

const LABEL: Record<VerdictKind, string> = {
  verified: 'Verified',
  disputed: 'Disputed',
  unmeasured: 'Unmeasured',
  'not-examined': 'Not Examined',
}

const COLOR: Record<VerdictKind, string> = {
  verified: 'text-verdict-verified',
  disputed: 'text-verdict-disputed',
  unmeasured: 'text-verdict-unmeasured',
  'not-examined': 'text-verdict-not-examined',
}

// Default tilt varies slightly per verdict so a row of stamps doesn't look
// mechanically identical — real ink stamps never land at the same angle
// twice.
const ROTATE: Record<VerdictKind, string> = {
  verified: '-rotate-6',
  disputed: '-rotate-7',
  unmeasured: '-rotate-[6.5deg]',
  'not-examined': '-rotate-8',
}

export function VerdictStamp({
  verdict,
  className,
}: {
  verdict: VerdictKind
  className?: string
}) {
  return (
    <span
      className={cn(
        'stamp-ink relative inline-flex select-none items-center justify-center gap-2 rounded-sm px-4 py-1.5',
        'font-mono text-xs font-medium tracking-[0.18em] uppercase',
        COLOR[verdict],
        ROTATE[verdict],
        className,
      )}
    >
      {/* Ink-bleed pass: a blurred, faintly offset duplicate behind the
          crisp label fakes uneven rubber-stamp pressure. CSS only. */}
      <span
        aria-hidden="true"
        className="absolute inset-0 rounded-sm opacity-40 blur-[0.5px]"
        style={{ boxShadow: '0 0 0 1px currentColor' }}
      />
      <span aria-hidden="true" className="h-1 w-1 rounded-full bg-current" />
      {LABEL[verdict]}
    </span>
  )
}
