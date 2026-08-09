import type { Metadata } from 'next'
import { InterviewFlow } from '@/components/candidate/interview-flow'

export const metadata: Metadata = {
  title: 'Start your interview — CogniHire',
  description:
    'Enter your interview code and check your camera and microphone before starting.',
}

export default async function InterviewPage({
  searchParams,
}: {
  searchParams: Promise<{ code?: string }>
}) {
  const { code } = await searchParams
  const normalized = code?.trim().toUpperCase()

  return <InterviewFlow code={normalized || undefined} />
}
