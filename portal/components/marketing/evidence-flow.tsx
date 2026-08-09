import { cn } from '@/lib/utils'

type Stage = {
  label: string
  note: string
  lines: number[]
  highlight?: boolean
}

const stages: Stage[] = [
  { label: 'Resume', note: 'Submitted by candidate', lines: [100, 82, 64, 90] },
  { label: 'Claims', note: 'Extracted statements', lines: [72, 100, 55] },
  { label: 'Interview', note: 'Questions asked', lines: [88, 60, 96, 70] },
  { label: 'Evidence', note: 'Quoted answers', lines: [100, 74, 88], highlight: true },
  { label: 'Report', note: 'Reviewed by humans', lines: [66, 92, 78, 58] },
]

export function EvidenceFlow() {
  return (
    <figure className="rounded-xl border border-border bg-card p-5 shadow-[0_1px_0_0_var(--border),0_24px_60px_-40px_oklch(0.19_0.018_264_/_0.35)] sm:p-7">
      <figcaption className="flex items-center justify-between gap-4 border-b border-border pb-4">
        <span className="label-mono text-muted-foreground">Evidence trail</span>
        <span className="label-mono text-muted-foreground">
          Traceable end to end
        </span>
      </figcaption>

      <ol className="mt-6 grid gap-4 sm:grid-cols-5 sm:gap-0">
        {stages.map((stage, index) => (
          <li
            key={stage.label}
            className={cn(
              'rise relative flex gap-4 sm:flex-col sm:gap-0 sm:px-3',
              index > 0 && 'sm:border-l sm:border-border',
            )}
            style={{ animationDelay: `${120 * index}ms` }}
          >
            <div
              aria-hidden="true"
              className="flex w-9 shrink-0 flex-col justify-center gap-[5px] sm:w-full sm:h-14 sm:justify-end"
            >
              {stage.lines.map((width, lineIndex) => (
                <span
                  key={lineIndex}
                  className={cn(
                    'block h-[2px] rounded-full',
                    stage.highlight && lineIndex === 0
                      ? 'bg-evidence'
                      : 'bg-foreground/15',
                  )}
                  style={{ width: `${width}%` }}
                />
              ))}
            </div>

            <div className="sm:mt-5">
              <p className="label-mono text-muted-foreground">
                {String(index + 1).padStart(2, '0')}
              </p>
              <h3 className="mt-1.5 text-sm font-medium tracking-[-0.01em]">
                {stage.label}
              </h3>
              <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
                {stage.note}
              </p>
            </div>
          </li>
        ))}
      </ol>
    </figure>
  )
}
