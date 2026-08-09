// Small status indicator shared across the workspace list pages. Reuses the
// existing brand tokens (accent = positive, destructive = negative,
// muted-foreground = neutral/pending) instead of introducing a new color
// system — this app has no "warning" token, so a stalled/needs-attention
// state uses destructive too, distinguished by label text, not a new hue.

import { cn } from '@/lib/utils'

export type PillTone = 'positive' | 'negative' | 'neutral'

export function StatusPill({
  label,
  tone = 'neutral',
}: {
  label: string
  tone?: PillTone
}) {
  return (
    <span
      className={cn(
        'label-mono inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1',
        tone === 'positive' && 'border-accent-foreground/25 bg-accent text-accent-foreground',
        tone === 'negative' && 'border-destructive/25 bg-destructive/10 text-destructive',
        tone === 'neutral' && 'border-border bg-muted text-muted-foreground',
      )}
    >
      {label}
    </span>
  )
}
