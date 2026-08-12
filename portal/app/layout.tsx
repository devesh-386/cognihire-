import { Analytics } from '@vercel/analytics/next'
import type { Metadata, Viewport } from 'next'
import { IBM_Plex_Mono, Inter_Tight, Roboto_Slab } from 'next/font/google'
import './globals.css'

// Roboto Slab for headings — a document/typewriter-adjacent slab that reads
// as a printed ledger rather than a soft app, matching the "Case File"
// design system (see app/globals.css header comment). Body/UI text stays
// Inter Tight — v0's layout and spacing were tuned around it, and its
// grotesk character pairs cleanly with a slab display face without
// competing for attention. IBM Plex Mono (below) stays as the fixed-width
// face for evidence/thresholds/timestamps.
const robotoSlab = Roboto_Slab({
  subsets: ['latin'],
  variable: '--font-roboto-slab',
  display: 'swap',
  weight: ['500', '600', '700'],
})

const interTight = Inter_Tight({
  subsets: ['latin'],
  variable: '--font-inter-tight',
  display: 'swap',
})

const plexMono = IBM_Plex_Mono({
  subsets: ['latin'],
  weight: ['400', '500'],
  variable: '--font-plex-mono',
  display: 'swap',
})

export const metadata: Metadata = {
  title: 'CogniHire — See the evidence behind every interview',
  description:
    'CogniHire turns candidate claims and interview conversations into grounded evidence that hiring teams can review. Evidence over opaque scores.',
  generator: 'v0.app',
  openGraph: {
    title: 'CogniHire — See the evidence behind every interview',
    description:
      'Grounded candidate evidence, from resume claims to interview answers. Final decisions stay with humans.',
    type: 'website',
  },
  icons: {
    icon: [
      {
        url: '/icon-light-32x32.png',
        media: '(prefers-color-scheme: light)',
      },
      {
        url: '/icon-dark-32x32.png',
        media: '(prefers-color-scheme: dark)',
      },
      {
        url: '/icon.svg',
        type: 'image/svg+xml',
      },
    ],
    apple: '/apple-icon.png',
  },
}

export const viewport: Viewport = {
  colorScheme: 'light',
  themeColor: '#fbfbfd',
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html
      lang="en"
      className={`light bg-background ${robotoSlab.variable} ${interTight.variable} ${plexMono.variable}`}
    >
      <body className="font-sans antialiased">
        {children}
        {process.env.NODE_ENV === 'production' && <Analytics />}
      </body>
    </html>
  )
}
