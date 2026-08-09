import Link from 'next/link'
import { Logo } from '@/components/site/logo'

const columns = [
  {
    heading: 'Platform',
    links: [
      { label: 'Product', href: '/#product' },
      { label: 'How it Works', href: '/#how-it-works' },
      { label: 'For Companies', href: '/#for-companies' },
      { label: 'For Candidates', href: '/#for-candidates' },
    ],
  },
  {
    heading: 'Company',
    links: [
      { label: 'About', href: '/about' },
      { label: 'Contact', href: '/contact' },
    ],
  },
  {
    heading: 'Legal',
    links: [
      { label: 'Privacy', href: '/privacy' },
      { label: 'Terms', href: '/terms' },
    ],
  },
]

export function SiteFooter() {
  return (
    <footer className="border-t border-border">
      <div className="mx-auto w-full max-w-6xl px-5 py-14 lg:px-8 lg:py-16">
        <div className="grid gap-12 md:grid-cols-[1.4fr_repeat(3,1fr)]">
          <div className="flex flex-col gap-4">
            <Logo />
            <p className="max-w-xs text-sm leading-relaxed text-muted-foreground">
              Evidence over opaque scores. Hiring teams review what candidates
              actually demonstrated.
            </p>
          </div>

          {columns.map((column) => (
            <nav key={column.heading} aria-label={column.heading}>
              <h2 className="label-mono text-muted-foreground">
                {column.heading}
              </h2>
              <ul className="mt-4 flex flex-col gap-2.5">
                {column.links.map((link) => (
                  <li key={link.label}>
                    <Link
                      href={link.href}
                      className="text-sm text-foreground/80 transition-colors hover:text-foreground"
                    >
                      {link.label}
                    </Link>
                  </li>
                ))}
              </ul>
            </nav>
          ))}
        </div>

        <div className="mt-14 flex flex-col gap-3 border-t border-border pt-6 sm:flex-row sm:items-center sm:justify-between">
          <p className="label-mono text-muted-foreground">
            © {new Date().getFullYear()} CogniHire
          </p>
          <p className="label-mono text-muted-foreground">
            Decisions stay with humans
          </p>
        </div>
      </div>
    </footer>
  )
}
