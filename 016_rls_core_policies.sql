-- 016_rls_core_policies.sql

ALTER TABLE invitations    ENABLE ROW LEVEL SECURITY;
ALTER TABLE guests         ENABLE ROW LEVEL SECURITY;
ALTER TABLE rsvp_responses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tenant_isolation" ON invitations
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

CREATE POLICY "public_invitation_read" ON invitations
  FOR SELECT
  USING (status = 'published');

CREATE POLICY "reseller_client_read" ON invitations
  FOR SELECT
  USING (
    tenant_id IN (
      SELECT tenant_id FROM reseller_tenants
      WHERE reseller_id = (auth.jwt() ->> 'reseller_id')::UUID
    )
  );

CREATE POLICY "tenant_isolation" ON guests
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

CREATE POLICY "tenant_isolation" ON rsvp_responses
  USING (
    invitation_id IN (
      SELECT id FROM invitations
      WHERE tenant_id = (auth.jwt() ->> 'tenant_id')::UUID
    )
  );
