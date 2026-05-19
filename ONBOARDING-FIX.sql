-- ══════════════════════════════════════════════════════════════
-- FIX: Onboarding flow — create_trial_account RPC + RLS fix
-- Run this in Supabase Dashboard → SQL Editor
-- ══════════════════════════════════════════════════════════════

-- Step 1: Debug — check current RLS policies on tenants
DO $$
DECLARE r RECORD;
BEGIN
  RAISE NOTICE '=== Current policies on tenants ===';
  FOR r IN SELECT policyname, cmd, with_check FROM pg_policies WHERE tablename = 'tenants' AND schemaname = 'public'
  LOOP
    RAISE NOTICE 'Policy: % | CMD: % | CHECK: %', r.policyname, r.cmd, r.with_check;
  END LOOP;
END $$;

-- Step 2: Fix tenants INSERT policy (ensure it exists and is correct)
DROP POLICY IF EXISTS "tenants_insert" ON tenants;
CREATE POLICY "tenants_insert" ON tenants FOR INSERT
  WITH CHECK (
    is_admin()
    OR owner_email = (auth.jwt() ->> 'email')
  );

-- Step 3: Fix tenant_users INSERT policy (must allow owner bootstrap)
DROP POLICY IF EXISTS "tu_insert" ON tenant_users;
CREATE POLICY "tu_insert" ON tenant_users FOR INSERT
  WITH CHECK (
    tenant_id IN (SELECT get_my_tenant_ids())
    OR is_admin()
    OR tenant_id IN (SELECT id FROM tenants WHERE owner_email = (auth.jwt() ->> 'email'))
  );

-- Step 4: Fix settings INSERT policy (must allow owner bootstrap)
DROP POLICY IF EXISTS "settings_insert" ON settings;
CREATE POLICY "settings_insert" ON settings FOR INSERT
  WITH CHECK (
    tenant_id IN (SELECT get_my_tenant_ids())
    OR is_admin()
    OR tenant_id IN (SELECT id FROM tenants WHERE owner_email = (auth.jwt() ->> 'email'))
  );

-- Step 5: Fix settings SELECT policy (owner can read before tenant_users exists)
DROP POLICY IF EXISTS "settings_select" ON settings;
CREATE POLICY "settings_select" ON settings FOR SELECT
  USING (
    tenant_id IN (SELECT get_my_tenant_ids())
    OR is_admin()
    OR tenant_id IN (SELECT id FROM tenants WHERE owner_email = (auth.jwt() ->> 'email'))
  );

-- Step 6: Fix tenant_banks INSERT policy
DROP POLICY IF EXISTS "banks_insert" ON tenant_banks;
CREATE POLICY "banks_insert" ON tenant_banks FOR INSERT
  WITH CHECK (
    tenant_id IN (SELECT get_my_tenant_ids())
    OR is_admin()
    OR tenant_id IN (SELECT id FROM tenants WHERE owner_email = (auth.jwt() ->> 'email'))
  );

-- Step 7: Fix email_log INSERT policy (needed for welcome email during trial)
DROP POLICY IF EXISTS "email_insert" ON email_log;
CREATE POLICY "email_insert" ON email_log FOR INSERT
  WITH CHECK (
    is_admin()
    OR tenant_id IN (SELECT get_my_tenant_ids())
    OR tenant_id IN (SELECT id FROM tenants WHERE owner_email = (auth.jwt() ->> 'email'))
  );

-- Step 8: Create atomic onboarding RPC function (fallback for RLS issues)
CREATE OR REPLACE FUNCTION public.create_trial_account(p_plan text DEFAULT 'starter', p_cycle text DEFAULT 'monthly', p_days int DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text;
  v_tenant_id uuid;
  v_expires timestamptz;
BEGIN
  -- Get the authenticated user's email
  v_email := auth.jwt() ->> 'email';
  IF v_email IS NULL THEN
    RETURN jsonb_build_object('error', 'Not authenticated');
  END IF;

  -- Check if user already has a tenant
  IF EXISTS (SELECT 1 FROM tenant_users WHERE email = v_email AND is_active = true) THEN
    RETURN jsonb_build_object('error', 'User already has an account');
  END IF;

  -- Calculate expiry
  v_expires := now() + (p_days || ' days')::interval;

  -- Create tenant
  INSERT INTO tenants (owner_email, plan, billing_cycle, plan_expires_at, is_active)
  VALUES (v_email, p_plan, p_cycle, v_expires, true)
  RETURNING id INTO v_tenant_id;

  -- Create tenant_user
  INSERT INTO tenant_users (tenant_id, email, role, accepted_at, is_active)
  VALUES (v_tenant_id, v_email, 'owner', now(), true);

  -- Create settings
  INSERT INTO settings (tenant_id, current_balance)
  VALUES (v_tenant_id, 0);

  RETURN jsonb_build_object(
    'id', v_tenant_id,
    'owner_email', v_email,
    'plan', p_plan,
    'billing_cycle', p_cycle,
    'plan_expires_at', v_expires,
    'is_active', true
  );
END;
$$;

-- Grant execute to authenticated and anon roles
GRANT EXECUTE ON FUNCTION public.create_trial_account(text, text, int) TO authenticated, anon;

-- Step 9: Create activate_paid_account RPC (for after payment)
CREATE OR REPLACE FUNCTION public.activate_paid_account(p_plan text, p_cycle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text;
  v_tenant_id uuid;
  v_expires timestamptz;
BEGIN
  v_email := auth.jwt() ->> 'email';
  IF v_email IS NULL THEN
    RETURN jsonb_build_object('error', 'Not authenticated');
  END IF;

  IF EXISTS (SELECT 1 FROM tenant_users WHERE email = v_email AND is_active = true) THEN
    RETURN jsonb_build_object('error', 'User already has an account');
  END IF;

  IF p_cycle = 'yearly' THEN
    v_expires := now() + interval '1 year';
  ELSE
    v_expires := now() + interval '1 month';
  END IF;

  INSERT INTO tenants (owner_email, plan, billing_cycle, plan_expires_at, is_active)
  VALUES (v_email, p_plan, p_cycle, v_expires, true)
  RETURNING id INTO v_tenant_id;

  INSERT INTO tenant_users (tenant_id, email, role, accepted_at, is_active)
  VALUES (v_tenant_id, v_email, 'owner', now(), true);

  INSERT INTO settings (tenant_id, current_balance)
  VALUES (v_tenant_id, 0);

  RETURN jsonb_build_object(
    'id', v_tenant_id,
    'owner_email', v_email,
    'plan', p_plan,
    'billing_cycle', p_cycle,
    'plan_expires_at', v_expires,
    'is_active', true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.activate_paid_account(text, text) TO authenticated, anon;

-- Step 10: Ensure GRANTS on tables are correct
GRANT ALL ON tenants TO authenticated;
GRANT ALL ON tenant_users TO authenticated;
GRANT ALL ON settings TO authenticated;
GRANT ALL ON tenant_banks TO authenticated;
GRANT ALL ON email_log TO authenticated;
GRANT ALL ON transactions TO authenticated;
GRANT ALL ON payments TO authenticated;

-- Done! 
-- After running this, the onboarding flow will use the RPC function 
-- which bypasses RLS with SECURITY DEFINER.
