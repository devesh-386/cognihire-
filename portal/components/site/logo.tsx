import Link from 'next/link'
import { cn } from '@/lib/utils'

export function LogoMark({ className }: { className?: string }) {
  return (
    <span
      aria-hidden="true"
      className={cn(
        'inline-flex size-7 items-center justify-center rounded-[7px] bg-foreground',
        className,
      )}
    >
      <svg viewBox="0 0 24 24" className="size-4" fill="none">
        <path
          d="M7 6.5h10M7 12h6.5M7 17.5h4"
          stroke="var(--background)"
          strokeWidth="1.6"
          strokeLinecap="round"
        />
        <circle cx="17.5" cy="16.5" r="3" stroke="var(--evidence)" strokeWidth="1.6" />
      </svg>
    </span>
  )
}

export function Logo({
  className,
  href = '/',
}: {
  className?: string
  href?: string
}) {
  return (
    <Link
      href={href}
      className={cn(
        'group inline-flex items-center gap-2.5 rounded-md outline-none focus-visible:ring-3 focus-visible:ring-ring/40',
        className,
      )}
    >
      <LogoMark />
      <span className="text-[0.95rem] font-medium tracking-[-0.01em]">
        CogniHire
      </span>
    </Link>
  )
}
