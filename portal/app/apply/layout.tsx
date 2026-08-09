import type { ReactNode } from 'react'
import { Logo } from '@/components/site/logo'

export default function ApplyLayout({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-svh flex-col">
      <header className="border-b border-border">
        <div className="mx-auto flex h-16 w-full max-w-3xl items-center justify-between px-5 lg:px-8">
          <Logo />
          <span className="label-mono text-muted-foreground">Apply</span>
        </div>
      </header>
      <main className="mx-auto w-full max-w-3xl flex-1 px-5 py-12 lg:px-8 lg:py-16">
        {children}
      </main>
      <footer className="border-t border-border">
        <div className="mx-auto w-full max-w-3xl px-5 py-6 lg:px-8">
          <p className="label-mono text-muted-foreground">
            Your résumé becomes claims, not a score · Decisions stay with humans
          </p>
        </div>
      </footer>
    </div>
  )
}
