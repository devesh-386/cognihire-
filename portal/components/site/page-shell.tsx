import type { ReactNode } from 'react'
import { SiteHeader } from '@/components/site/site-header'
import { SiteFooter } from '@/components/site/site-footer'

export function PageShell({
  eyebrow,
  title,
  intro,
  children,
}: {
  eyebrow?: string
  title: string
  intro?: string
  children?: ReactNode
}) {
  return (
    <>
      <SiteHeader />
      <main>
        <div className="mx-auto w-full max-w-3xl px-5 pt-16 pb-20 lg:px-8 lg:pt-24 lg:pb-28">
          <header className="border-b border-border pb-10">
            {eyebrow ? (
              <p className="label-mono text-muted-foreground">{eyebrow}</p>
            ) : null}
            <h1 className="mt-5 text-4xl leading-[1.05] font-medium tracking-[-0.035em] text-balance sm:text-5xl">
              {title}
            </h1>
            {intro ? (
              <p className="mt-5 text-base leading-relaxed text-muted-foreground text-pretty">
                {intro}
              </p>
            ) : null}
          </header>
          {children ? <div className="mt-10">{children}</div> : null}
        </div>
      </main>
      <SiteFooter />
    </>
  )
}

export function Prose({ children }: { children: ReactNode }) {
  return (
    <div className="flex flex-col gap-6 text-[0.9375rem] leading-relaxed text-muted-foreground [&_h2]:text-base [&_h2]:font-medium [&_h2]:tracking-[-0.01em] [&_h2]:text-foreground [&_strong]:font-medium [&_strong]:text-foreground">
      {children}
    </div>
  )
}
