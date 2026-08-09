import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

export function Section({
  id,
  eyebrow,
  title,
  description,
  children,
  className,
  bordered = true,
}: {
  id?: string
  eyebrow?: string
  title?: ReactNode
  description?: ReactNode
  children?: ReactNode
  className?: string
  bordered?: boolean
}) {
  return (
    <section
      id={id}
      className={cn(
        'scroll-mt-16',
        bordered && 'border-b border-border',
        className,
      )}
    >
      <div className="mx-auto w-full max-w-6xl px-5 py-16 lg:px-8 lg:py-24">
        {(eyebrow || title || description) && (
          <header className="max-w-2xl">
            {eyebrow ? (
              <p className="label-mono text-muted-foreground">{eyebrow}</p>
            ) : null}
            {title ? (
              <h2 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] text-balance sm:text-4xl">
                {title}
              </h2>
            ) : null}
            {description ? (
              <p className="mt-4 text-base leading-relaxed text-muted-foreground text-pretty">
                {description}
              </p>
            ) : null}
          </header>
        )}
        {children}
      </div>
    </section>
  )
}
