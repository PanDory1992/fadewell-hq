const clean=value=>String(value??'').trim().replace(',','.');

export const MEASUREMENT_FIELDS=[
  {key:'waist',label:'Talia na płasko',min:20,max:80},
  {key:'rise',label:'Stan z przodu',min:15,max:60},
  {key:'inseam',label:'Nogawka wewnętrzna',min:30,max:130},
  {key:'leg_opening',label:'Otwór nogawki na płasko',min:8,max:60},
  {key:'overall_length',label:'Długość całkowita',min:50,max:150},
];

export function buildOwnerMeasurementPayload(values={}){
  const payload={};
  for(const field of MEASUREMENT_FIELDS){
    const raw=clean(values[field.key]);
    if(!raw)continue;
    if(!/^\d{1,3}(?:\.\d{1,2})?$/.test(raw))throw new Error(`${field.label}: wpisz jedną liczbę w cm.`);
    const cm=Number(raw);
    if(!Number.isFinite(cm)||cm<field.min||cm>field.max)throw new Error(`${field.label}: dozwolony zakres to ${field.min}–${field.max} cm.`);
    payload[field.key]=cm;
  }
  return payload;
}

export function existingOwnerMeasurements(facts={}){
  const stored=facts.measurements||{};
  return Object.fromEntries(MEASUREMENT_FIELDS.map(field=>{
    const value=stored[field.key];
    return [field.key,value?.source==='OWNER_CONFIRMED'&&Number.isFinite(Number(value.cm))?String(value.cm):''];
  }));
}
