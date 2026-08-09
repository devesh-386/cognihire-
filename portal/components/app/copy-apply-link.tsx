'use client'

import { useState } from 'react'
import { Check, Link2 } from 'lucide-react'

export function CopyApplyLink({ roleId }: { roleId: string }) {
  const [copied, setCopied] = useState(false)

  async function copy() {
    const url = `${window.location.origin}/apply/${roleId}`
    await navigator.clipboard.writeText(url)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }

  return (
    <button
      type="button"
      onClick={copy}
      className="flex items-center gap-1.5 text-xs font-medium text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
    >
      {copied ? (
        <>
          <Check aria-hidden="true" className="size-3.5" />
          Copied
        </>
      ) : (
        <>
          <Link2 aria-hidden="true" className="size-3.5" />
          Copy application link
        </>
      )}
    </button>
  )
}
