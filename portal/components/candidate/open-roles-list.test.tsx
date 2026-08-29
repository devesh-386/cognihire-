/**
 * Where the public open-roles list sends a candidate.
 *
 * Every role used to link to the portal's own résumé-upload page, which
 * opened a second intake path alongside the auto-generated Google Form that
 * the Apps Script trigger and the intake poller already feed. A role whose
 * intake has a form now hands off to that form, so applicants for the same
 * role all enter through one pipeline.
 *
 * The fallback is the half most likely to regress: a role with no active
 * intake must still be listed and still reach `/apply/{id}`, not vanish and
 * not render a dead link.
 */

import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'

const listOpenRoles = vi.fn()

vi.mock('@/lib/gateway', () => ({
  listOpenRoles: (...args: unknown[]) => listOpenRoles(...args),
}))

// next/link renders an <a> in the DOM; the real component pulls in router
// context this test has no need for.
vi.mock('next/link', () => ({
  default: ({ href, children, ...rest }: any) => (
    <a href={href} {...rest}>
      {children}
    </a>
  ),
}))

import { OpenRolesList } from './open-roles-list'

const FORM = 'https://docs.google.com/forms/d/e/1FAIpQLS-example/viewform'

function linkFor(title: string): HTMLAnchorElement {
  const link = screen.getByText(title).closest('a')
  if (!link) throw new Error(`no link rendered for "${title}"`)
  return link as HTMLAnchorElement
}

describe('OpenRolesList', () => {
  beforeEach(() => {
    listOpenRoles.mockReset()
  })

  it('sends a role with a generated form to that form', async () => {
    listOpenRoles.mockResolvedValue({
      roles: [
        {
          id: 'role-1',
          title: 'Backend Engineer',
          organization_name: 'CogniHire Demo Co',
          application_url: FORM,
        },
      ],
    })

    render(<OpenRolesList />)

    await waitFor(() => expect(screen.getByText('Backend Engineer')).toBeTruthy())
    const link = linkFor('Backend Engineer')
    expect(link.getAttribute('href')).toBe(FORM)
    // Opened in a new tab so the candidate does not lose the portal, and
    // rel'd so the form's tab cannot reach back through window.opener.
    expect(link.getAttribute('target')).toBe('_blank')
    expect(link.getAttribute('rel')).toContain('noopener')
  })

  it('falls back to the portal apply page when the role has no form', async () => {
    listOpenRoles.mockResolvedValue({
      roles: [
        {
          id: 'role-2',
          title: 'Machine Learning Engineer',
          organization_name: 'CogniHire Demo Co',
          application_url: null,
        },
      ],
    })

    render(<OpenRolesList />)

    await waitFor(() =>
      expect(screen.getByText('Machine Learning Engineer')).toBeTruthy(),
    )
    const link = linkFor('Machine Learning Engineer')
    expect(link.getAttribute('href')).toBe('/apply/role-2')
    expect(link.getAttribute('target')).toBeNull()
  })

  it('lists both kinds together rather than hiding the formless one', async () => {
    listOpenRoles.mockResolvedValue({
      roles: [
        { id: 'a', title: 'Backend Engineer', organization_name: 'Demo', application_url: FORM },
        { id: 'b', title: 'Software Engineer', organization_name: 'Demo', application_url: null },
      ],
    })

    render(<OpenRolesList />)

    await waitFor(() => expect(screen.getByText('Software Engineer')).toBeTruthy())
    expect(linkFor('Backend Engineer').getAttribute('href')).toBe(FORM)
    expect(linkFor('Software Engineer').getAttribute('href')).toBe('/apply/b')
  })

  it('treats a role with no application_url field at all as formless', async () => {
    // A backend that predates this field, or a cached response from one.
    listOpenRoles.mockResolvedValue({
      roles: [{ id: 'c', title: 'Backend Engineer', organization_name: 'Demo' }],
    })

    render(<OpenRolesList />)

    await waitFor(() => expect(screen.getByText('Backend Engineer')).toBeTruthy())
    expect(linkFor('Backend Engineer').getAttribute('href')).toBe('/apply/c')
  })
})
