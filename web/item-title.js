// One HQ naming rule: Vinted title when verified; internal purchase shorthand only as fallback.
export const itemTitle=item=>[item?.live_title,item?.name].map(value=>String(value||'').trim()).find(Boolean)||'Bez nazwy';
