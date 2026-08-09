import Link from 'next/link'
import type { ComponentProps } from 'react'
import type { VariantProps } from 'class-variance-authority'

import { buttonVariants } from '@/components/ui/button'
import { cn } from '@/lib/utils'

/**
 * An anchor styled as a button. Use this instead of <Button render={<Link />} />
 * so that native button semantics are never claimed by a link element.
 */
function ButtonLink({
  className,
  variant = 'default',
  size = 'default',
  ...props
}: ComponentProps<typeof Link> & VariantProps<typeof buttonVariants>) {
  return (
    <Link
      data-slot="button"
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  )
}

export { ButtonLink }
