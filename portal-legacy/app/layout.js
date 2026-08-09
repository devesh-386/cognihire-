import { Fraunces, Inter } from "next/font/google";
import "./globals.css";

// Fraunces for display, Inter for text. The brief behind the desktop app's
// palette calls the look "understated luxury"; a warm optical serif on the
// headings is what carries that, and it is the one thing a system-font stack
// cannot fake.
// No `weight` on purpose: next/font only exposes a variable font's custom
// axes (SOFT/WONK here) when the font is loaded as a variable, and pinning a
// static weight makes those axes an error rather than a no-op.
const display = Fraunces({
  subsets: ["latin"],
  variable: "--font-display",
  display: "swap",
  axes: ["SOFT", "WONK"],
});

const body = Inter({
  subsets: ["latin"],
  variable: "--font-body",
  display: "swap",
});

export const metadata = {
  title: "CogniHire — Interviews that check the claim, not the candidate",
  description:
    "CogniHire reads a résumé, finds the specific claims in it, and runs an interview that asks the candidate to substantiate them. You get evidence, not a score.",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en" className={`${display.variable} ${body.variable}`}>
      <body style={{ fontFamily: "var(--font-body), system-ui, sans-serif" }}>
        {children}
      </body>
    </html>
  );
}
