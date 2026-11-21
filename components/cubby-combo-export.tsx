"use client";
import {useState,type FormEvent} from "react";
import {parseCubbyComboExport} from "@/lib/cubby-combo-export.mjs";

type Props={facilities:{id:string;name:string;active:boolean}[];onImport:(payload:any)=>Promise<any>};
export default function CubbyComboExport({facilities,onImport}:Props){
 const [facility,setFacility]=useState("");
 const [file,setFile]=useState<File|null>(null);
 const [busy,setBusy]=useState(false);
 const [error,setError]=useState("");
 const [summary,setSummary]=useState("");
 async function importExport(event:FormEvent){
  event.preventDefault();
  if(!facility||!file||busy)return;
  setBusy(true);setError("");setSummary("");
  try{
   if(file.size>750000)throw Error("The CSV file is too large.");
   const {facilityName,records}=parseCubbyComboExport(await file.text());
   const local=facilities.find(row=>row.id===facility);
   if(!local||!window.confirm(`Reconcile the fresh Cubby export for ${facilityName} with ${local.name}?`))return;
   let result;
   try{result=await onImport({facility,observed_at:new Date(file.lastModified).toISOString(),records});}
   catch{throw Error("The import could not be completed. Try again after Cubby sync finishes.");}
   if(result.error)throw Error(result.error);
   setSummary(`${result.matched} of ${result.submitted} matched. ${result.classificationsCorrected} status corrections, ${result.combinationsRecovered} combinations recovered, ${result.combinationsMatched} existing combinations verified, ${result.combinationConflicts} combination conflicts, ${result.combinationValuesMissing} empty export values, ${result.blockedByNotification} blocked by notification activity.`);
   setFile(null);(event.target as HTMLFormElement).reset();
  }catch(e){setError(e instanceof Error?e.message:"Unable to import the export.");}
  finally{setBusy(false);}
 }
 return <section className="surface">
  <div className="section-heading"><div><h2>Reconcile Cubby export</h2><p>In Cubby, export an unfiltered Combo Locks CSV for one facility. Upload the original file after the warehouse sync. The import fills missing codes and checks existing codes against the export.</p></div></div>
  <form className="cubby-export-form" onSubmit={importExport}>
   <label>Facility<select required value={facility} disabled={busy} onChange={e=>setFacility(e.target.value)}><option value="">Choose facility</option>{facilities.filter(f=>f.active).map(f=><option key={f.id} value={f.id}>{f.name}</option>)}</select></label>
   <label>Combo Locks CSV<input type="file" accept=".csv,text/csv" required disabled={busy} onChange={e=>setFile(e.target.files?.[0]||null)}/></label>
   <button className="primary" disabled={busy||!file||!facility}>{busy?"Reconciling…":"Reconcile export"}</button>
  </form>
  {error&&<p role="alert">{error}</p>}{summary&&<p role="status">{summary}</p>}
 </section>;
}
