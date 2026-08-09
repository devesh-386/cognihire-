'use client'

import Link from 'next/link'
import { useEffect, useState } from 'react'
import { ArrowUpRight, Menu, X } from 'lucide-react'
import { ButtonLink } from '@/components/ui/button-link'
import { Logo } from '@/components/site/logo'
import { cn } from '@/lib/utils'

const navigation = [
  { label: 'How it Works', href: '/#how-it-works' },
  { label: 'Have a code?', href: '/#for-candidates' },
  { label: 'Desktop App', href: '/desktop' },
  { label: 'About', href: '/about' },
]

export function SiteHeader() {
  const [open, setOpen] = useState(false)
  const [scrolled, setScrolled] = useState(false)

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8)
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  useEffect(() => {
    document.body.style.overflow = open ? 'hidden' : ''
    return () => {
      document.body.style.overflow = ''
    }
  }, [open])

  return (
    <header
      className={cn(
        'sticky top-0 z-50 border-b transition-colors duration-300',
        scrolled
          ? 'border-border bg-background/85 backdrop-blur-md'
          : 'border-transparent bg-background',
      )}
    >
      <div className="mx-auto flex h-16 w-full max-w-6xl items-center justify-between px-5 lg:px-8">
        <Logo />

        <nav aria-label="Main" className="hidden lg:block">
          <ul className="flex items-center gap-7">
            {navigation.map((item) => (
              <li key={item.label}>
                <Link
                  href={item.href}
                  className="text-[0.8125rem] text-muted-foreground transition-colors hover:text-foreground"
                >
                  {item.label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>

        <div className="hidden items-center gap-4 lg:flex">
          <Link
            href="/company"
            className="text-[0.8125rem] text-muted-foreground transition-colors hover:text-foreground"
          >
            For companies
          </Link>
          <ButtonLink
            href="/apply"
            className="h-9 rounded-full px-4 text-[0.8125rem]"
          >
            Apply now
          </ButtonLink>
        </div>

        <button
          type="button"
          onClick={() => setOpen((v) => !v)}
          aria-expanded={open}
          aria-label={open ? 'Close menu' : 'Open menu'}
          className="-mr-2 inline-flex size-10 items-center justify-center rounded-md text-foreground lg:hidden"
        >
          {open ? <X className="size-5" /> : <Menu className="size-5" />}
        </button>
      </div>

      {open ? (
        <div className="fixed inset-x-0 top-16 bottom-0 z-50 border-t border-border bg-background lg:hidden">
          <div className="flex h-full flex-col justify-between px-5 py-8">
            <nav aria-label="Mobile">
              <ul className="flex flex-col gap-1">
                {navigation.map((item) => (
                  <li key={item.label}>
                    <Link
                      href={item.href}
                      onClick={() => setOpen(false)}
                      className="flex items-center justify-between border-b border-border py-4 text-lg tracking-[-0.01em]"
                    >
                      {item.label}
                      <ArrowUpRight className="size-4 text-muted-foreground" />
                    </Link>
                  </li>
                ))}
              </ul>
            </nav>
            <div className="flex flex-col gap-3">
              <ButtonLink
                href="/apply"
                onClick={() => setOpen(false)}
                className="h-12 rounded-full text-sm"
              >
                Apply now
              </ButtonLink>
              <ButtonLink
                href="/company"
                onClick={() => setOpen(false)}
                variant="outline"
                className="h-12 rounded-full text-sm"
              >
                For companies
              </ButtonLink>
            </div>
          </div>
        </div>
      ) : null}
    </header>
  )
}
