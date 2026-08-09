import { SiteHeader } from '@/components/site/site-header'
import { SiteFooter } from '@/components/site/site-footer'
import { Hero } from '@/components/marketing/hero'
import { WhyCogniHire } from '@/components/marketing/why-cognihire'
import { HowItWorks } from '@/components/marketing/how-it-works'
import { EvidenceReport } from '@/components/marketing/evidence-report'
import { ForCompanies } from '@/components/marketing/for-companies'
import { ForCandidates } from '@/components/marketing/for-candidates'
import { CompanyCta } from '@/components/marketing/company-cta'

export default function HomePage() {
  return (
    <>
      <SiteHeader />
      <main>
        <Hero />
        <WhyCogniHire />
        <HowItWorks />
        <EvidenceReport />
        <ForCompanies />
        <ForCandidates />
        <CompanyCta />
      </main>
      <SiteFooter />
    </>
  )
}
