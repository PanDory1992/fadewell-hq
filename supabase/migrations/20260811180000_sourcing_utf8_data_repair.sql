-- Repair sourcing copy that was transcoded while the original seed migration
-- was sent to Supabase. All Polish copy below is carried as ASCII hex so the
-- transport cannot reinterpret its UTF-8 bytes a second time.

update public.hq_sourcing_policies
set version_label=convert_from(decode('563120c2b72033302073616c6573202f2033302064617973','hex'),'UTF8'),
    updated_at=now()
where policy_id='SRC-2026-08-11-V1';

with repairs(cell_id,qualifier_hex,rationale_hex) as (values
  ('G-501-33-35',null::text,'4e616a6d6f636e69656a737a6120706f777461727a616c6e61206b6f6dc3b3726b613b2074796c6b6f20772072616d61636820736c6f7475207265706c6163656d656e742e'),
  ('G-505-30-32',null::text,'506f777461727a616c6e79206d6f64656c20772063656e7472616c6e796d207061c59b6d696520726f7a6d696172752e'),
  ('G-505-33-35',null::text,'506f777461727a616c6e79206d6f64656c20772063656e7472616c6e796d207061c59b6d696520726f7a6d696172752e'),
  ('G-WRANGLER-30-32',null::text,'5772616e676c65722074796c6b6f207a206e69736b696d206b6f737a74656d2077656ac59b6369612e'),
  ('G-WRANGLER-33-35',null::text,'5772616e676c65722074796c6b6f207a206e69736b696d206b6f737a74656d2077656ac59b6369612e'),
  ('G-550-30-32','57796d6167616e79207265616c6e7920777972c3b3c5bc6e696b3a206572612c20706f63686f647a656e69652c207761736820616c626f207374616e2e','4e6965206b7570756a207a77796bc582656a20706172792074796c6b6f20646c617465676f2c20c5bc65206d61206e756d6572203535302e'),
  ('G-550-33-35','57796d6167616e79207265616c6e7920777972c3b3c5bc6e696b3a206572612c20706f63686f647a656e69652c207761736820616c626f207374616e2e','4e6965206b7570756a207a77796bc582656a20706172792074796c6b6f20646c617465676f2c20c5bc65206d61206e756d6572203535302e'),
  ('G-615-30-32','57796d6167616e79207265616c6e7920777972c3b3c5bc6e696b3a206572612c20706f63686f647a656e69652c207761736820616c626f207374616e2e','3631352074796c6b6f206a616b6f20706172612077797261c5ba6e6965206c6570737a61206f64207a77796bc58265676f2073746f636b752e'),
  ('G-615-33-35','57796d6167616e79207265616c6e7920777972c3b3c5bc6e696b3a206572612c20706f63686f647a656e69652c207761736820616c626f207374616e2e','3631352074796c6b6f206a616b6f20706172612077797261c5ba6e6965206c6570737a61206f64207a77796bc58265676f2073746f636b752e'),
  ('R-SMALL-WAIST',null::text,'526f7a6d69617220706f7a6120626965c5bcc48563796d2072647a656e69656d20706f707974752e'),
  ('R-LEE-GENERIC','57796ac48574656b2077796d616761206b6f6e6b7265746e65676f206b6f6c656b636a6f6e6572736b6965676f20646f776f64752e','47656e657279637a6e79204c656520706f7a6f7374616a65207a616d6b6e69c49974792e'),
  ('R-ORDINARY-219','4e696520646f7479637a792070617279207a2075646f6b756d656e746f77616e796d20727a61646b696d20777972c3b3c5bc6e696b69656d2e','5a77796bc5826120706172612077796d6167616ac48563612063656e7920706f7779c5bc656a20323139207ac582206e6965207763686f647a6920646f20736f757263696e67752e'),
  ('R-OFF-NICHE',null::text,'4f66662d6e69636865207a616d6b6e69c49974652c20676479206261636b6c6f672070727a656b7261637a61206c696d69742e')
)
update public.hq_sourcing_policy_cells c
set qualifier=case when r.qualifier_hex is null then null else convert_from(decode(r.qualifier_hex,'hex'),'UTF8') end,
    rationale=convert_from(decode(r.rationale_hex,'hex'),'UTF8')
from repairs r
where c.policy_id='SRC-2026-08-11-V1' and c.cell_id=r.cell_id;

with repairs(item_id,required_check_hex) as (values
  ('DEN-202','537072617764c5ba207374616e2069207a61706163683b206f706973207a616b757075207a617769657261207379676e61c58220e2809e536d72c3b364e2809d2e'),
  ('DEN-264','557a757065c5826e696a20706f6d69617279206920706f747769657264c5ba20676f746f776fc59bc487207072657a656e7461636a692e'),
  ('DEN-225','557a757065c5826e696a20706f6d69617279206920706f747769657264c5ba207374616e2070727a6564207a646ac4996369616d692e'),
  ('DEN-223','4b6170697461c5822070727a656b7261637a61206e6f7779206c696d6974206b6f6dc3b3726b693b20737072617764c5ba207374616e2069207265616c6ec4852063656ec4992077796ac59b6369612e'),
  ('DEN-285','557a757065c5826e696a20706f6d69617279206920706f747769657264c5ba20676f746f776fc59bc487207072657a656e7461636a692e')
)
update public.hq_sourcing_replacement_candidates c
set required_check=convert_from(decode(r.required_check_hex,'hex'),'UTF8'),updated_at=now()
from repairs r
where c.policy_id='SRC-2026-08-11-V1' and c.item_id=r.item_id;

create or replace view public.hq_sourcing_gate_current
with (security_invoker=true) as
with active_policy as (
  select * from public.hq_sourcing_policies where status='ACTIVE' order by effective_from desc limit 1
), metrics as (
  select
    count(*) filter (where ledger_status='LISTED-BACKLOG')::integer as listed_count,
    count(*) filter (where ledger_status='UNLISTED-BACKLOG')::integer as unlisted_count,
    coalesce(sum(total_capital) filter (where ledger_status='UNLISTED-BACKLOG'),0)::numeric(12,2) as unlisted_capital
  from public.hq_ledger_items
), flow as (
  select p.policy_id,
    (select count(*) from public.hq_ledger_items i where i.ledger_status='SOLD' and i.sold_on>=p.effective_from)::integer as sales_since_policy,
    (select count(*) from public.hq_sourcing_replacement_candidates c where c.policy_id=p.policy_id and c.status='RELEASED')::integer as replacements_released
  from active_policy p
)
select p.policy_id,p.version_label,p.effective_from,p.effective_until,p.max_unlisted_count,p.max_unlisted_capital,p.slot_rule,
  m.listed_count,m.unlisted_count,m.unlisted_capital,f.sales_since_policy,f.replacements_released,
  (f.sales_since_policy-f.replacements_released)::integer as slot_balance,
  greatest(f.sales_since_policy-f.replacements_released,0)::integer as available_replacement_slots,
  (m.unlisted_count>p.max_unlisted_count) as count_over_limit,
  (m.unlisted_capital>p.max_unlisted_capital) as capital_over_limit,
  case when m.unlisted_count>p.max_unlisted_count or m.unlisted_capital>p.max_unlisted_capital then 'REPLACEMENT_ONLY' else 'OPEN' end as gate_state,
  case when m.unlisted_count>p.max_unlisted_count or m.unlisted_capital>p.max_unlisted_capital
    then convert_from(decode('4e6f777920736f757263696e67207a616d6b6e69c49974792e204b61c5bc646120706f7477696572647a6f6e61207370727a656461c5bc206f747769657261206a6564656e20736c6f7420646c61206b6f6c656a6e656a2070617279207a206261636b6c6f67752e','hex'),'UTF8') collate "default"
    else convert_from(decode('4261636b6c6f67206d6965c59b6369207369c4992077206c696d6963696520706f6c6974796b693b20736f757263696e67206d6fc5bc65207772c3b36369c487207779c582c485637a6e69652077207a69656c6f6e796368206b6f6dc3b3726b6163682e','hex'),'UTF8') collate "default" end as gate_reason
from active_policy p cross join metrics m join flow f using (policy_id);

revoke all on table public.hq_sourcing_gate_current from public;
grant select on table public.hq_sourcing_gate_current to authenticated;

do $$
declare remaining integer;
begin
  with rendered(copy) as (
    select version_label from public.hq_sourcing_policies where status='ACTIVE'
    union all select qualifier from public.hq_sourcing_policy_cells where policy_id='SRC-2026-08-11-V1'
    union all select rationale from public.hq_sourcing_policy_cells where policy_id='SRC-2026-08-11-V1'
    union all select required_check from public.hq_sourcing_replacement_candidates where policy_id='SRC-2026-08-11-V1'
    union all select gate_reason from public.hq_sourcing_gate_current
  )
  select count(*) into remaining from rendered
  where copy is not null and (
    position(chr(194) in copy)>0 or position(chr(195) in copy)>0 or
    position(chr(196) in copy)>0 or position(chr(197) in copy)>0 or
    position(chr(226) in copy)>0
  );
  if remaining>0 then raise exception 'Sourcing UTF-8 repair incomplete: % malformed value(s)',remaining; end if;
end $$;
