import { Analytics } from '@vercel/analytics/next'
import type { Metadata, Viewport } from 'next'
import { Fraunces, IBM_Plex_Mono, Inter_Tight } from 'next/font/google'
import './globals.css'

// Fraunces for headings, matching the Flutter app + portal brand (see
// app/globals.css header comment). Body/UI text stays Inter Tight — v0's
// layout and spacing were tuned around it.
const fraunces = Fraunces({
  subsets: ['latin'],
  variable: '--font-fraunces',
  display: 'swap',
  axes: ['SOFT', 'WONK'],
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
      className={`light bg-background ${fraunces.variable} ${interTight.variable} ${plexMono.variable}`}
    >
      <body className="font-sans antialiased">
        {children}
        {process.env.NODE_ENV === 'production' && <Analytics />}
      </body>
    </html>
  )
}
