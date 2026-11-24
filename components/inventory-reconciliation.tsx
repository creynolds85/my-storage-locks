"use client";

import {useEffect, useState} from "react";
import {RefreshCw} from "lucide-react";
import {statuses} from "@/lib/csv.mjs";

const differenceReasons = [
  "retained_in_msl", "absent_from_cubby", "absent_from_msl", "serial_identity_conflict",
  "status_assignment_conflict", "source_version_conflict", "binding_mismatch",
  "classification_mismatch", "combination_conflict",
];
const filters = [
  {value: "all", label: "All review records"},
  {value: "unclassified", label: "Unclassified"},
  {value: "source", label: "Absent from BigQuery", reasons: ["absent_from_cubby", "retained_in_msl"]},
  {value: "msl", label: "Absent from MSL", reasons: ["absent_from_msl"]},
  {value: "conflict", label: "Conflicts", reasons: differenceReasons.slice(3)},
  {value: "retained", label: "Retained pending review", reasons: ["retained_in_msl"]},
  {value: "code", label: "No stored combination", reasons: ["combination_missing"]},
  {value: "evidence", label: "Evidence gaps", reasons: [
    "local_identity_unverified", "identity_link_unverified", "mirror_review", "cubby_locked",
    "cubby_remove_lock", "purpose_unverified", "prior_combination_conflict", "csv_row_unmatched",
  ]},
];
const reasonLabels: Record<string, string> = {
  unclassified: "Unclassified in MSL",
  retained_in_msl: "Retained in MSL pending Cubby disposition",
  absent_from_cubby: "Cubby ID absent from the BigQuery snapshot",
  absent_from_msl: "No MSL record linked to this Cubby ID",
  local_identity_unverified: "Cubby identity needs verification",
  identity_link_unverified: "Mirror link needs verification",
  serial_identity_conflict: "Serial or identity conflict",
  status_assignment_conflict: "Cubby status and placement disagree",
  source_version_conflict: "Different Cubby values share the same source version",
  mirror_review: "Mirror evidence needs review",
  binding_mismatch: "Facility, unit, or active assignment differs",
  classification_mismatch: "Classification differs from the verified Cubby label",
  cubby_locked: "Cubby shows Locked without a specific purpose",
  cubby_remove_lock: "Cubby shows Remove lock without a specific purpose",
  purpose_unverified: "Specific purpose unavailable in Cubby evidence",
  combination_conflict: "Official CSV combination differs",
  prior_combination_conflict: "Earlier CSV combination conflict needs a fresh comparison",
  combination_missing: "No combination stored in MSL",
  csv_row_unmatched: "Latest CSV evidence for this serial could not be matched",
};
const workerStates: Record<string, string> = {
  operational: "Operational", failed: "Latest check failed", delayed: "Check overdue",
  paused: "Paused", unknown: "No successful check recorded",
};
const timeFormat = new Intl.DateTimeFormat("en-US", {
  dateStyle: "medium", timeStyle: "medium", timeZone: "America/New_York",
});
const pageSize = 25;
const statusLabels: Record<string, string> = statuses;

type ReviewItem = {
  serial?: string | null;
  sourceId?: string | null;
  facility?: string | null;
  sourceFacility?: string | null;
  facilityId?: string | null;
  status?: string | null;
  unit?: string | null;
  sourceUnit?: string | null;
  sourceStatus?: string | null;
  mirrorIssue?: string | null;
  observedAt?: string | null;
  reasons: string[];
};

type Reconciliation = {
  asOf: string;
  mode: string;
  inventory: number;
  matched: number | null;
  sourceCount: number | null;
  unclassified: number;
  retained: number | null;
  differences: number | null;
  missingCodes: number;
  purposeUnverified: number | null;
  verifiedCodes: number | null;
  csvCodes: number | null;
  warehouseCodes: number | null;
  workerState: string;
  lastCheckedAt: string | null;
  lastSuccessAt: string | null;
  lastErrorCode: string | null;
  lastFullSyncAt: string | null;
  sourceSnapshotAt: string | null;
  sourceComplete: boolean;
  sourceFresh: boolean;
  capabilities: {snapshotBasis?: string; combinations?: boolean; explicitPurpose?: boolean} | null;
  latestCsvReconciledAt: string | null;
  latestCsvObservedAt: string | null;
  latestCsvFacility: string | null;
  legacyCsvEvidenceAt: string | null;
  items: ReviewItem[];
};

type Props = {
  revision: number;
  read: (signal: AbortSignal) => Promise<Reconciliation | null>;
};

function Time({value}: {value?: string | null}) {
  if (!value) return <>Unavailable</>;
  return <time dateTime={value}>{timeFormat.format(new Date(value))} ET</time>;
}

function Status({item, fresh}: {item: ReviewItem; fresh: boolean}) {
  const difference = item.reasons.some(reason => differenceReasons.includes(reason));
  const observation = item.reasons.includes("retained_in_msl") ||
    item.reasons.includes("absent_from_cubby") || item.reasons.includes("absent_from_msl");
  return <span className={"reconciliation-tag" + (difference && fresh && !observation ? " confirmed" : "")}>
    {difference ? (fresh ? (observation ? "Snapshot difference" : "Confirmed conflict") : "Earlier snapshot finding") : "Evidence needed"}
  </span>;
}

export default function InventoryReconciliation({revision, read}: Props) {
  const [data, setData] = useState<Reconciliation | null>(null);
  const [filter, setFilter] = useState("all");
  const [facility, setFacility] = useState("");
  const [search, setSearch] = useState("");
  const [limit, setLimit] = useState(pageSize);
  const [refresh, setRefresh] = useState(0);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    setFailed(false);
    read(controller.signal).then(report => {
      if (controller.signal.aborted) return;
      if (!report) throw Error("reconciliation_unavailable");
      setData(report);
    }).catch(() => {
      if (!controller.signal.aborted) setFailed(true);
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false);
    });
    return () => controller.abort();
  }, [read, revision, refresh]);

  const reasons = filters.find(option => option.value === filter)?.reasons ?? [filter];
  const needle = search.trim().toLowerCase();
  const reviewFacilities = [...new Set(data?.items.flatMap(item => [item.facility, item.sourceFacility])
    .filter((name): name is string => Boolean(name)))].sort();
  const items = data?.items.filter(item =>
    (filter === "all" || item.reasons.some(reason => reasons.includes(reason))) &&
    (!facility || item.facility === facility || item.sourceFacility === facility) &&
    (!needle || [item.serial, item.sourceId, item.unit, item.sourceUnit].some(value => value?.toLowerCase().includes(needle)))
  ) ?? [];
  const unresolved = data && (!data.sourceComplete || !data.sourceFresh || data.workerState !== "operational" ||
    data.items.length > 0 || data.verifiedCodes !== data.inventory || !data.latestCsvReconciledAt);

  return <section className="surface reconciliation" aria-labelledby="reconciliation-title" aria-busy={loading}>
    <div className="section-heading">
      <div>
        <h2 id="reconciliation-title">Inventory reconciliation</h2>
        <p>Company-wide{data?.mode === "mirror" && " · Cubby is authoritative in Mirror Mode"}</p>
      </div>
      <button type="button" className="secondary" disabled={loading} onClick={() => setRefresh(value => value + 1)}>
        <RefreshCw size={15} aria-hidden="true"/> Refresh
      </button>
    </div>
    {loading && !data && <p role="status">Loading reconciliation…</p>}
    {failed && <p role="alert">{data ? "Refresh failed. Showing the last loaded report." : "Reconciliation could not be loaded. Try refreshing."}</p>}
    {data && <>
      <dl className="reconciliation-metrics">
        <div><dt>Total MSL inventory</dt><dd>{data.inventory}</dd></div>
        <div><dt>Matched inventory fields</dt><dd>{data.matched ?? "—"}</dd></div>
        <div><dt>Unmatched or conflicting</dt><dd>{data.differences ?? "—"}</dd></div>
        <div><dt>Unclassified</dt><dd>{data.unclassified}</dd></div>
        <div><dt>Retained pending review</dt><dd>{data.retained ?? "—"}</dd></div>
      </dl>
      <p className="reconciliation-note">Matched inventory fields use the latest complete BigQuery snapshot. Purpose and combination verification are tracked separately.</p>

      <dl className="reconciliation-sync" aria-label="Cubby synchronization">
        <div>
          <dt>MSL lock sync · {workerStates[data.workerState] ?? "Unavailable"}</dt>
          <dd>Last success <Time value={data.lastSuccessAt}/></dd>
          <dd>Last check <Time value={data.lastCheckedAt}/></dd>
          {data.lastErrorCode && <dd>Latest error <code>{data.lastErrorCode}</code></dd>}
        </div>
        <div>
          <dt>BigQuery source · {data.sourceComplete ? (data.sourceFresh ? "Current" : "Stale") : "Coverage unavailable"}</dt>
          <dd>Source watermark <Time value={data.sourceSnapshotAt}/></dd>
          <dd>Last full sync <Time value={data.lastFullSyncAt}/></dd>
          {data.sourceCount != null && <dd>{data.sourceCount} source records</dd>}
        </div>
        <div>
          <dt>Official CSV reconciliation</dt>
          {data.latestCsvReconciledAt ? <>
            <dd>Last reconciled <Time value={data.latestCsvReconciledAt}/></dd>
            <dd>Export <Time value={data.latestCsvObservedAt}/></dd>
            <dd>{data.latestCsvFacility}</dd>
          </> : <>
            <dd>No completed import timestamp recorded</dd>
            {data.legacyCsvEvidenceAt && <dd>Latest recorded export evidence <Time value={data.legacyCsvEvidenceAt}/></dd>}
          </>}
        </div>
      </dl>

      <div className="reconciliation-readiness">
        <h3>Transition readiness · {unresolved ? "Review required" : "Owner approval required"}</h3>
        {!data.sourceComplete && <p>Current source coverage is unavailable. Refresh after the next complete sync before assessing source differences.</p>}
        {data.sourceComplete && !data.sourceFresh && <p>The BigQuery watermark is older than 95 minutes. Confirm findings against a fresh source before acting.</p>}
        {data.workerState !== "operational" && <p>Review the lock sync status before relying on the mirror.</p>}
        <p>
          {data.purposeUnverified != null && <>{data.purposeUnverified} active Cubby assignments lack verified purpose. </>}
          {data.verifiedCodes != null && <>{data.verifiedCodes} of {data.inventory} combinations have matching current evidence
            {data.csvCodes != null && data.warehouseCodes != null && ` (${data.csvCodes} via CSV, ${data.warehouseCodes} via BigQuery)`}. </>}
          {data.missingCodes > 0 && <>{data.missingCodes} {data.missingCodes === 1 ? "lock has" : "locks have"} no stored combination.</>}
        </p>
        {data.capabilities?.explicitPurpose === false && <p>BigQuery does not supply the exact Combo Locks purpose. Use a fresh facility export for supported labels.</p>}
        {data.capabilities?.combinations === false && <p>BigQuery does not supply combination values. Use official CSV evidence for code comparison.</p>}
        <p>Cutover requires explicit owner approval.</p>
      </div>

      <div className="reconciliation-review">
        <h3>Review records</h3>
        <div className="reconciliation-filters">
          <label>Finding
            <select value={filter} onChange={event => {setFilter(event.target.value); setLimit(pageSize);}}>
              {filters.map(option => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
          <label>Review facility
            <select value={facility} onChange={event => {setFacility(event.target.value); setLimit(pageSize);}}>
              <option value="">All facilities</option>
              {reviewFacilities.map(name => <option key={name}>{name}</option>)}
            </select>
          </label>
          <label>Serial, Cubby ID, or unit
            <input type="search" value={search} onChange={event => {setSearch(event.target.value); setLimit(pageSize);}}/>
          </label>
        </div>
        <p className="reconciliation-note" role="status">
          Showing {Math.min(items.length, limit)} of {items.length} {items.length === 1 ? "record" : "records"} · Report <Time value={data.asOf}/>
        </p>
        {items.length === 0 && <p>No recorded findings match these filters.</p>}
        {items.length > 0 && <ul className="reconciliation-records">
          {items.slice(0, limit).map(item => <li key={JSON.stringify([item.facilityId, item.serial, item.sourceId, item.reasons])}>
            <div>
              <strong>{item.serial || item.sourceId || "Serial unavailable"}</strong>
              <small>{item.facility || "Facility unresolved"}</small>
              {item.serial && item.sourceId && <small>{item.sourceId}</small>}
            </div>
            <div>
              {item.status && <small>MSL · {statusLabels[item.status] ?? item.status}{item.unit ? " · Unit " + item.unit : ""}</small>}
              {item.sourceStatus && <small>Cubby · {item.sourceStatus}{item.sourceUnit ? " · Unit " + item.sourceUnit : ""}</small>}
              {item.sourceFacility && item.sourceFacility !== item.facility && <small>Cubby facility · {item.sourceFacility}</small>}
              {item.observedAt && <small>CSV evidence · <Time value={item.observedAt}/></small>}
            </div>
            <div>
              <Status item={item} fresh={data.sourceFresh}/>
              <small>{item.reasons.map(reason => reasonLabels[reason] ?? reason).join(" · ")}</small>
              {item.mirrorIssue && <small><code>{item.mirrorIssue}</code></small>}
            </div>
          </li>)}
        </ul>}
        {items.length > limit && <button type="button" className="secondary" onClick={() => setLimit(value => value + pageSize)}>
          Show more records
        </button>}
      </div>
    </>}
  </section>;
}
