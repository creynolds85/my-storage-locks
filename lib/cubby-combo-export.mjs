import Papa from 'papaparse';

export function parseCubbyComboExport(csv){
 const {data,errors,meta}=Papa.parse(csv,{header:true,skipEmptyLines:'greedy',dynamicTyping:false});
 const required=['Serial code','Facility','Unit Number','Status','Combination'];
 if(errors.length||!required.every(name=>meta.fields?.includes(name))||data.length<1||data.length>1000){
  throw Error('Choose an official Combo Locks CSV containing 1–1,000 locks.');
 }
 const facilities=new Set(data.map(row=>row.Facility.trim()));
 if(facilities.size!==1||facilities.has(''))throw Error('Export a single Cubby facility at a time.');
 const records=data.map(row=>{
  const unit=row['Unit Number'].trim();
  return {serial:row['Serial code'].trim(),unit:unit===''||unit==='-'||unit==="'-"?null:unit,
   label:row.Status.trim(),combination:row.Combination||null};
 });
 if(records.some(row=>!/^[A-Za-z0-9]{1,100}$/.test(row.serial))||
  new Set(records.map(row=>row.serial.toLowerCase())).size!==records.length)throw Error('The CSV contains an invalid or duplicate serial.');
 return {facilityName:[...facilities][0],records};
}
