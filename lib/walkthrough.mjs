import {sourceDate} from './automation/cubby.mjs';
export {WALKTHROUGH_ISSUES} from './walkthrough-issues.mjs';
const collator=new Intl.Collator('en',{numeric:true,sensitivity:'base'});
export function orderedUnits(units){return [...units].sort((a,b)=>{
 const x=Number.isSafeInteger(a.walkthroughOrder)?a.walkthroughOrder:null,y=Number.isSafeInteger(b.walkthroughOrder)?b.walkthroughOrder:null;
 if(x!==null&&y!==null&&x!==y)return x-y;if(x!==null&&y===null)return -1;if(y!==null&&x===null)return 1;
 return collator.compare(a.name,b.name)||String(a.name).localeCompare(String(b.name))||String(a.unitId).localeCompare(String(b.unitId));
})}
export function classifyUnit(unit,lease,auction){
 if(auction)return 'auction';
 if(unit.overlocked===true||lease?.overlockNeeded===true)return 'overlock';
 if(unit.free===true&&!unit.leaseId)return 'vacant';
 if(unit.free===false&&lease?.leaseId===unit.leaseId&&lease.moveOutDate==null)return 'occupied';
 return 'unknown';
}
function collection(data,key){if(!Array.isArray(data?.[key])||data[key].length>=1000)throw Error('walkthrough_source_incomplete_'+key+'_'+(Array.isArray(data?.[key])?data[key].length:'missing'));return data[key]}
export async function fetchWalkthroughSource(client,link,now=Date.now()){
 const f=collection(await client.search('facilities/search',{facilityId:link.sourceFacilityId}),'facilities').filter(f=>f.facilityId===link.sourceFacilityId);
 if(f.length!==1)throw Error('walkthrough_facility_unverified');
 const today=sourceDate(now,f[0].timeZone);
 const [u,l,a]=await Promise.all([
  client.search('units/search',{facilityId:link.sourceFacilityId}),
  client.search('leases/search',{facilityId:link.sourceFacilityId,activeOnOrAfter:today,activeOnOrBefore:today},['customer']),
  client.search('auctions/search',{facilityId:link.sourceFacilityId})
 ]);
 const units=collection(u,'units'),leases=collection(l,'leases'),customers=collection(l,'customers'),auctions=collection(a,'auctions');
 if(new Set(units.map(u=>u.unitId)).size!==units.length||units.some(u=>!u.unitId||!u.name||u.facilityId!==link.sourceFacilityId)||leases.some(l=>l.facilityId!==link.sourceFacilityId))throw Error('walkthrough_facility_mismatch');
 const customerMap=new Map(customers.map(c=>[c.customerId,c.name||[c.firstName,c.lastName].filter(Boolean).join(' ')]));
 const leaseMap=new Map(leases.map(l=>[l.leaseId,l]));const auctionMap=new Map();
 for(const auction of auctions){if(!Array.isArray(auction.auctionedLeases))throw Error('walkthrough_auction_incomplete');for(const item of auction.auctionedLeases)if(!['CANCELLED','COMPLETE'].includes(item.status))auctionMap.set(item.unitId,item);}
 const ordered=orderedUnits(units);
 return {units:ordered.map(u=>{const lease=leaseMap.get(u.leaseId),auction=auctionMap.get(u.unitId);return {unitId:u.unitId,label:u.name,kind:classifyUnit(u,lease,auction),tenantName:lease?customerMap.get(lease.customerId)||null:null,auctionStatus:auction?.status||null,order:Number.isSafeInteger(u.walkthroughOrder)?u.walkthroughOrder:null,unrentable:u.rentability?.rentable===false&&u.free===true}}),ordering:units.every(u=>Number.isSafeInteger(u.walkthroughOrder))&&new Set(units.map(u=>u.walkthroughOrder)).size===units.length?'cubby':'cubby_with_natural_fallback',observedAt:new Date(now).toISOString()};
}
