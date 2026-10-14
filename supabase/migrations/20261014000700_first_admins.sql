-- The first people who can sign in. Everyone else is added on the Members
-- page. Display names are placeholders; edit them there.
insert into public.members (email, display_name, role, is_super_admin)
select v.email, v.display_name, v.role::public.member_role, true
from (values
  ('depedros@cppasd.com', 'depedros', 'president'),
  ('depedroshawn@gmail.com', 'depedroshawn', null)
) as v (email, display_name, role)
where not exists (select 1 from public.members m where lower(m.email) = lower(v.email));
