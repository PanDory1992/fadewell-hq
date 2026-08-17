-- "Confirmation needed" Vinted mail is a non-transactional prompt. It must
-- remain auditable, but it must never wait in the owner resolver or touch DEN.
update public.hq_external_events
set
  event_type = 'NOISE',
  state = 'AUTO_DISMISSED',
  evidence = coalesce(evidence, '{}'::jsonb) || jsonb_build_object(
    'template_id', 'confirmation_needed_trash_en_v1',
    'auto_dismissal_reason', 'Vinted confirmation-needed mail has no DEN or ledger action',
    'auto_dismissed_at', now()
  )
where source = 'GMAIL_VINTED'
  and state = 'NEEDS_REVIEW'
  and coalesce(evidence->>'template_id', '') = 'confirmation_needed_en_v1';
