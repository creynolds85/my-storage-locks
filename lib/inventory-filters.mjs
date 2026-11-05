// Presentation categories map to existing database statuses; physical color is unrelated.
export const inventoryCategories = [
  {id:"", label:"All Locks", cardLabel:"Total Locks", color:"#64748B", statuses:[]},
  {id:"available", label:"Available", color:"#1683F8", statuses:["available"]},
  {id:"overlock", label:"Overlocked", color:"#DC2626", statuses:["overlock"]},
  {id:"vacant", label:"Vacant", color:"#16A34A", statuses:["vacant"]},
  {id:"auction", label:"Auction", color:"#25292F", statuses:["auction"]},
  {id:"unavailable", label:"Missing / Damaged", color:"#D97706", statuses:["missing","retired"]},
];
export const inventoryFilters = [
  ...inventoryCategories,
  {id:"missing", label:"Missing / Lost", color:"#D97706", statuses:["missing"]},
  {id:"retired", label:"Damaged / Retired", color:"#D97706", statuses:["retired"]},
];
export function filterLabel(id){return inventoryFilters.find(c=>c.id===id)?.label||"All Locks"}
export function categoryCount(counts,id){
  const category=inventoryCategories.find(c=>c.id===id);
  return (id?category?.statuses||[]:inventoryCategories.flatMap(c=>c.statuses))
    .reduce((sum,status)=>sum+Number(counts[status]||0),0);
}
export function applyStatusFilter(query,id){
  const statuses=inventoryFilters.find(c=>c.id===id)?.statuses||[];
  return statuses.length>1?query.in("status",statuses):statuses.length===1?query.eq("status",statuses[0]):query;
}
export function readInventoryRoute(search,role,facilities,fallbackScope){
  const params=new URLSearchParams(search);
  const requestedScope=params.get("facility")||fallbackScope;
  const scope=requestedScope==="all"&&role==="admin"||facilities.some(f=>f.id===requestedScope)
    ?requestedScope:role==="admin"?"all":facilities[0]?.id||"";
  const requestedView=params.get("view")||"dashboard";
  const view=["dashboard","inventory","activity",...(role==="admin"?["admin"]:[])].includes(requestedView)?requestedView:"dashboard";
  const requestedFilter=params.get("status")||"";
  return {scope,view,filter:inventoryFilters.some(c=>c.id===requestedFilter)?requestedFilter:""};
}
export function inventoryRouteUrl(href,{view,filter,scope}){
  const url=new URL(href);
  if(view==="dashboard")url.searchParams.delete("view");else url.searchParams.set("view",view);
  if(filter)url.searchParams.set("status",filter);else url.searchParams.delete("status");
  if(scope)url.searchParams.set("facility",scope);else url.searchParams.delete("facility");
  return url.pathname+url.search+url.hash;
}
