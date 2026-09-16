-- Starter catalog. Edit prices freely — nothing here is load-bearing code.
insert into commission_types (id, label, base_price, is_estimate, sort_order) values
  ('portrait1', 'Portrait — 1 character', 45, false, 1),
  ('portrait2', 'Portrait — 2 characters', 70, false, 2),
  ('half1', 'Half body — 1 character', 65, false, 3),
  ('half2', 'Half body — 2 characters', 100, false, 4),
  ('full1', 'Full body — 1 character', 90, false, 5),
  ('full2', 'Full body — 2 characters', 140, false, 6),
  ('scenebasic1', 'Scene, basic — 1 character', 120, true, 7),
  ('scenebasic2', 'Scene, basic — 2 characters', 170, true, 8),
  ('scenedetail1', 'Scene, detailed — 1 character', 180, true, 9),
  ('scenedetail2', 'Scene, detailed — 2 characters', 250, true, 10)
on conflict (id) do nothing;

insert into extras (id, label, price, is_percentage, percentage) values
  ('rush', 'Rush delivery', null, true, 25),
  ('extra_char', 'Additional character', 30, false, null),
  ('bg_detail', 'Detailed background', 25, false, null),
  ('commercial', 'Commercial licence add-on', null, true, 50)
on conflict (id) do nothing;
