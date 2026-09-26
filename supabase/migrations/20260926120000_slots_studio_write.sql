-- Allow the studio (authenticated) account to fully manage availability
-- slots from the admin calendar — previously only updates were permitted,
-- which blocked creating new open dates.
drop policy if exists "studio update slots" on slots;
create policy "studio full access slots" on slots for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
