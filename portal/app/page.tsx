import { SiteHeader } from '@/components/site/site-header'
import { SiteFooter } from '@/components/site/site-footer'
import { Hero } from '@/components/marketing/hero'
import { ForCandidates } from '@/components/marketing/for-candidates'
import { HowItWorks } from '@/components/marketing/how-it-works'
import { WhyCogniHire } from '@/components/marketing/why-cognihire'
import { EvidenceReport } from '@/components/marketing/evidence-report'
import { CandidateCta } from '@/components/marketing/candidate-cta'

export default function HomePage() {
  return (
    <>
      <SiteHeader />
      <main>
        <Hero />
        <ForCandidates />
        <HowItWorks />
        <WhyCogniHire />
        <EvidenceReport />
        <CandidateCta />
      </main>
      <SiteFooter />
    </>
  )
}
