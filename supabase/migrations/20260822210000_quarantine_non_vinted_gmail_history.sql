-- Gmail History is account-wide. A previous sync version converted messages
-- from other senders into empty UNCLASSIFIED review work. Preserve the audit
-- rows, but remove them from the owner resolver and make the quarantine reason
-- explicit. The Edge Function now rejects these messages before intake.

update public.hq_external_events
set state = 'AUTO_DISMISSED',
    evidence = coalesce(evidence, '{}'::jsonb) || jsonb_build_object(
      'auto_dismissal_reason', 'Non-Vinted sender entered through account-wide Gmail History cursor',
      'quarantined_at', now(),
      'quarantine_version', 'non_vinted_sender_v1'
    )
where source = 'GMAIL_VINTED'
  and state = 'NEEDS_REVIEW'
  and event_type = 'UNCLASSIFIED'
  and coalesce(evidence->>'from', '') !~* '(^|<)no-reply@vinted\.pl>?\s*$';
