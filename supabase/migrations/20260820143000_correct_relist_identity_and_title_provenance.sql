-- Correct one false automatic relist and make the identity boundary durable.
-- Manual Storefront hiding is an owner decision: the system resolver may not
-- reinterpret a newly seen public listing as that hidden DEN.

begin;

create or replace function public.apply_hq_system_relist(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  item_key text := nullif(coalesce(p, '{}'::jsonb)->>'item_id', '');
  owner_hidden boolean := false;
begin
  select coalesce(item.storefront_hidden, false)
  into owner_hidden
  from public.hq_ledger_items item
  where item.item_id = item_key;

  if owner_hidden then
    return jsonb_build_object(
      'deferred', true,
      'reason', 'owner_hidden_requires_manual_resolution',
      'item_id', item_key
    );
  end if;

  return public.apply_hq_relist_transition(p, 'SYSTEM');
end;
$$;

revoke all on function public.apply_hq_system_relist(jsonb) from public, anon, authenticated;
grant execute on function public.apply_hq_system_relist(jsonb) to service_role;

create or replace function public.enrich_hq_listing_event_title_provenance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  previous_ledger_title text;
  current_vinted_title text;
  previous_vinted_title text;
  old_vinted_id text;
begin
  if new.event_type <> 'LISTED'
     or new.source <> 'SYSTEM'
     or position('tytuł w Ledger przed Vinted' in coalesce(new.detail, '')) > 0 then
    return new;
  end if;

  select coalesce(nullif(btrim(item.manual_title), ''), nullif(btrim(item.name), ''), item.item_id),
         nullif(btrim(item.live_title), '')
  into previous_ledger_title, current_vinted_title
  from public.hq_ledger_items item
  where item.item_id = new.item_id;

  if coalesce(new.external_key, '') like 'auto-relist-%' then
    old_vinted_id := split_part(new.external_key, '-', 3);
    select nullif(btrim(snapshot.title), '')
    into previous_vinted_title
    from public.hq_listing_snapshots snapshot
    where snapshot.vinted_item_id = old_vinted_id
    order by snapshot.captured_at desc, snapshot.id desc
    limit 1;

    new.detail := format(
      U&'Tytu\0142 w Ledger przed Vinted: \201E%s\201D; tytu\0142 Vinted: \201E%s\201D \2192 \201E%s\201D; %s',
      coalesce(previous_ledger_title, 'brak'),
      coalesce(previous_vinted_title, 'brak'),
      coalesce(current_vinted_title, 'brak'),
      coalesce(new.detail, '')
    );
  else
    new.detail := format(
      U&'Tytu\0142 w Ledger przed Vinted: \201E%s\201D \2192 \201E%s\201D; %s',
      coalesce(previous_ledger_title, 'brak'),
      coalesce(current_vinted_title, 'brak'),
      coalesce(new.detail, '')
    );
  end if;

  return new;
end;
$$;

drop trigger if exists hq_listing_event_title_provenance on public.hq_ledger_events;
create trigger hq_listing_event_title_provenance
before insert on public.hq_ledger_events
for each row execute function public.enrich_hq_listing_event_title_provenance();

do $$
declare
  den093 public.hq_ledger_items%rowtype;
  den274 public.hq_ledger_items%rowtype;
  old_snapshot record;
  new_snapshot record;
  correction_evidence jsonb := jsonb_build_object(
    'correction', 'miki_confirmed_identity_2026-08-20',
    'wrong_item_id', 'DEN-093',
    'correct_item_id', 'DEN-274',
    'vinted_item_id', '9719056890'
  );
begin
  select * into den093 from public.hq_ledger_items where item_id = 'DEN-093' for update;
  select * into den274 from public.hq_ledger_items where item_id = 'DEN-274' for update;

  if den093.vinted_item_id is distinct from '9719056890'
     or den274.vinted_item_id is not null then
    return;
  end if;

  select title, price_pln, photo_url, captured_at
  into old_snapshot
  from public.hq_listing_snapshots
  where vinted_item_id = '9342042409'
  order by captured_at desc, id desc
  limit 1;

  select title, price_pln, photo_url, captured_at
  into new_snapshot
  from public.hq_listing_snapshots
  where vinted_item_id = '9719056890'
  order by captured_at desc, id desc
  limit 1;

  if old_snapshot.captured_at is null or new_snapshot.captured_at is null then
    raise exception 'Identity correction requires verified snapshots for both Vinted IDs';
  end if;

  update public.hq_ledger_items
  set vinted_item_id = '9342042409',
      listing_url = 'https://www.vinted.pl/items/9342042409',
      live_title = old_snapshot.title,
      live_list_price = old_snapshot.price_pln,
      last_live_check_on = old_snapshot.captured_at::date,
      last_photo_url = old_snapshot.photo_url,
      item_dna = jsonb_set(
        coalesce(item_dna, '{}'::jsonb),
        '{evidence,auto_from_listing_title}',
        to_jsonb(old_snapshot.title),
        true
      ),
      version = version + 1,
      updated_at = now()
  where item_id = 'DEN-093';

  update public.hq_ledger_items
  set listed = true,
      ledger_status = 'LISTED-BACKLOG',
      listed_on = coalesce(listed_on, new_snapshot.captured_at::date),
      vinted_item_id = '9719056890',
      listing_url = 'https://www.vinted.pl/items/9719056890',
      live_title = new_snapshot.title,
      live_list_price = new_snapshot.price_pln,
      last_live_check_on = new_snapshot.captured_at::date,
      last_photo_url = new_snapshot.photo_url,
      version = version + 1,
      updated_at = now()
  where item_id = 'DEN-274';

  insert into public.hq_vinted_listing_lineage(
    vinted_item_id, item_id, state, last_seen_at, replaced_by_vinted_item_id,
    evidence, resolved_at, resolved_by
  ) values (
    '9342042409', 'DEN-093', 'ACTIVE', old_snapshot.captured_at, null,
    correction_evidence || jsonb_build_object('restored_previous_listing', true), now(), 'MANUAL'
  )
  on conflict (vinted_item_id) do update
  set item_id = excluded.item_id,
      state = 'ACTIVE',
      last_seen_at = excluded.last_seen_at,
      replaced_by_vinted_item_id = null,
      evidence = public.hq_vinted_listing_lineage.evidence || excluded.evidence,
      resolved_at = now(),
      resolved_by = 'MANUAL';

  insert into public.hq_vinted_listing_lineage(
    vinted_item_id, item_id, state, last_seen_at, replaced_by_vinted_item_id,
    evidence, resolved_at, resolved_by
  ) values (
    '9719056890', 'DEN-274', 'ACTIVE', new_snapshot.captured_at, null,
    correction_evidence || jsonb_build_object('correct_current_listing', true), now(), 'MANUAL'
  )
  on conflict (vinted_item_id) do update
  set item_id = excluded.item_id,
      state = 'ACTIVE',
      last_seen_at = excluded.last_seen_at,
      replaced_by_vinted_item_id = null,
      evidence = public.hq_vinted_listing_lineage.evidence || excluded.evidence,
      resolved_at = now(),
      resolved_by = 'MANUAL';

  update public.hq_vinted_relist_candidates
  set state = 'DISMISSED',
      last_reason = 'incorrect_identity_corrected_by_owner',
      evidence = evidence || correction_evidence,
      resolved_at = now(),
      resolved_by = 'MANUAL',
      updated_at = now()
  where item_id = 'DEN-093'
    and old_vinted_item_id = '9342042409'
    and new_vinted_item_id = '9719056890';

  insert into public.hq_ledger_events(
    item_id, event_type, occurred_on, amount, detail, source, external_key
  ) values (
    'DEN-274', 'LISTED', new_snapshot.captured_at::date, new_snapshot.price_pln,
    format(
      U&'Korekta Miki: oferta 9719056890 nale\017Cy do DEN-274. Tytu\0142 w Ledger przed Vinted: \201E%s\201D \2192 \201E%s\201D.',
      coalesce(nullif(btrim(den274.manual_title), ''), den274.name),
      new_snapshot.title
    ),
    'MANUAL', 'miki-correct-9719056890-den274-20260820'
  ) on conflict (external_key) do nothing;

  insert into public.hq_ledger_events(
    item_id, event_type, occurred_on, amount, detail, source, external_key
  ) values (
    'DEN-093', 'ADJUSTMENT', current_date, null,
    'INVALIDATES_LEDGER_EVENT #543 · Korekta Miki: błędne automatyczne przypisanie oferty 9719056890 do DEN-093 zostało unieważnione. Przywrócono właściwe Vinted ID 9342042409; storefront_hidden=true pozostało bez zmian.',
    'MANUAL', 'miki-restore-den093-after-false-relist-20260820'
  ) on conflict (external_key) do nothing;
end;
$$;

commit;
