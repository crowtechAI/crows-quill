-- Private bucket for reference/sketch/delivery files.
insert into storage.buckets (id, name, public)
values ('commission-files', 'commission-files', false)
on conflict (id) do nothing;

create policy "studio read commission-files" on storage.objects for select
  using (bucket_id = 'commission-files' and auth.role() = 'authenticated');
create policy "studio write commission-files" on storage.objects for insert
  with check (bucket_id = 'commission-files' and auth.role() = 'authenticated');
create policy "studio update commission-files" on storage.objects for update
  using (bucket_id = 'commission-files' and auth.role() = 'authenticated');
create policy "studio delete commission-files" on storage.objects for delete
  using (bucket_id = 'commission-files' and auth.role() = 'authenticated');
