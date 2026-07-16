// One HQ naming rule: Vinted title when verified; internal purchase shorthand only as fallback.
export const itemTitle=item=>[item?.live_title,item?.name].map(value=>String(value||'').trim()).find(Boolean)||'Bez nazwy';

// Item DNA, denim Pricing and denim Sourcing share one scope rule. The ledger
// stays category-complete; only clearly non-denim garment types opt out.
const scopeText=value=>String(value||'').toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]+/g,' ').trim();
const nonDenimGarment=/\b(?:shirt|blazer|coat|sweater|sweatshirt|hoodie|jacket|tee|tshirt|shoe|shoes|boots|buty|koszul[ae]|plaszcz\w*|marynark\w*|sweter\w*|bluz\w*|kurtk\w*|katan\w*|sukienk\w*|spodnic\w*)\b/;
export const isDenimItem=item=>!nonDenimGarment.test(scopeText(itemTitle(item)));
