'use client'

import { WorkspaceList } from '@/components/app/resource-list'
import { WorkspaceBody, WorkspaceHeader } from '@/components/app/app-shell'
import { CopyApplyLink } from '@/components/app/copy-apply-link'
import { listRoles } from '@/lib/gateway'

export default function RolesPage() {
  return (
    <>
      <WorkspaceHeader
        title="Roles"
        description="A role describes what matters for a position, which is what interview questions are grounded against."
      />
      <WorkspaceBody>
        <WorkspaceList
          fetcher={listRoles}
          resourceKey="roles"
          emptyTitle="No roles yet"
          emptyBody="Roles created for your organization will appear here."
          renderItem={(role: any) => (
            <div className="flex items-center justify-between gap-4">
              <div>
                <p className="text-sm font-medium tracking-[-0.01em]">
                  {role.title}
                </p>
                {role.required_skills ? (
                  <p className="mt-1 text-sm text-muted-foreground">
                    {Array.isArray(role.required_skills)
                      ? role.required_skills.join(', ')
                      : role.required_skills}
                  </p>
                ) : null}
              </div>
              <CopyApplyLink roleId={role.id} />
            </div>
          )}
        />
      </WorkspaceBody>
    </>
  )
}
