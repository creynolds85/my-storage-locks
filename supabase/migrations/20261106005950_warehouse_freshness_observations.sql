-- Read-only Cubby observation history. No lock mutations and no SMS gate changes.
create table automation.warehouse_control(id boolean primary key default true check(id),first_started_at timestamptz,last_started_at timestamptz,last_finished_at timestamptz,last_success_at timestamptz,owner uuid,lease_until timestamptz,last_error_code text);
insert into automation.warehouse_control(id) values(true);
create table automation.warehouse_observations(id uuid primary key default gen_random_uuid(),observed_at timestamptz not null default now(),state text not null,error_code text,document jsonb not null default '{}');
create index warehouse_observed_time on automation.warehouse_observations(observed_at desc);
create table automation.warehouse_record_versions(table_name text not null,record_hash text not null,version_hash text not null,source_at text,source_marker text,first_seen_at timestamptz not null,baseline boolean not null,utc_verified boolean not null,latency_eligible boolean not null,detection_latency_seconds numeric,primary key(table_name,record_hash,version_hash));
alter table automation.warehouse_control enable row level security;
alter table automation.warehouse_observations enable row level security;
alter table automation.warehouse_record_versions enable row level security;
revoke all on automation.warehouse_control,automation.warehouse_observations,automation.warehouse_record_versions from public,anon,authenticated;

create function automation.warehouse_probe(operation text,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg automation.warehouse_control;o jsonb;t jsonb;r jsonb;is_baseline boolean;at_time timestamptz;source_time timestamptz;clean_tables jsonb:='[]';begin
 if operation='warehouse_claim' then
  update automation.warehouse_control set first_started_at=coalesce(first_started_at,clock_timestamp()),last_started_at=clock_timestamp(),owner=(p->>'owner')::uuid,lease_until=clock_timestamp()+interval '110 seconds'
  where id and (lease_until is null or lease_until<clock_timestamp()) and (last_started_at is null or last_started_at<clock_timestamp()-interval '50 seconds') returning * into cfg;
  if not found then return null;end if;
  return jsonb_build_object('firstStartedAt',cfg.first_started_at);
 elsif operation='warehouse_finish' then
  select * into cfg from automation.warehouse_control where id for update;
  if cfg.owner is distinct from (p->>'owner')::uuid then return null;end if;
  if p->>'errorCode' is not null then
   update automation.warehouse_control set owner=null,lease_until=null,last_finished_at=clock_timestamp(),last_error_code=left(p->>'errorCode',80) where id;
   insert into automation.warehouse_observations(state,error_code) values('failed',left(p->>'errorCode',80));return jsonb_build_object('saved',true);
  end if;
  o:=p->'observation';at_time:=(o->>'observedAt')::timestamptz;
  if pg_column_size(o)>500000 or o->>'state'<>'connected' or jsonb_array_length(o->'tables')>12 or o->>'eligibleForAutomaticCodeDisclosure'<>'false' then raise exception 'Invalid warehouse observation';end if;
  for t in select value from jsonb_array_elements(o->'tables') loop
   if t->>'name' not in ('facilities','leases','payments','units','contacts','book_entries','cubby_events','unit_turnover','lease_auctions') then raise exception 'Invalid warehouse table';end if;
   is_baseline:=not exists(select 1 from automation.warehouse_observations w cross join lateral jsonb_array_elements(w.document->'tables') previous where previous->>'name'=t->>'name' and previous->>'readable'='true');
   if jsonb_array_length(coalesce(t->'records','[]'))>200 then raise exception 'Too many warehouse samples';end if;
   for r in select value from jsonb_array_elements(coalesce(t->'records','[]')) loop
    if r->>'recordHash' !~ '^[A-Fa-f0-9]{64}$' or r->>'versionHash' !~ '^[A-Fa-f0-9]{64}$' then raise exception 'Only hashed source identities permitted';end if;
    source_time:=case when r->>'utcVerified'='true' then (r->>'sourceAt')::timestamptz else null end;
    insert into automation.warehouse_record_versions(table_name,record_hash,version_hash,source_at,source_marker,first_seen_at,baseline,utc_verified,latency_eligible,detection_latency_seconds)
    values(t->>'name',r->>'recordHash',r->>'versionHash',left(r->>'sourceAt',60),left(r->>'marker',60),at_time,is_baseline,coalesce((r->>'utcVerified')::boolean,false),coalesce((r->>'latencyEligible')::boolean,false),
     case when not is_baseline and r->>'latencyEligible'='true' and source_time>=cfg.first_started_at and source_time<=at_time and coalesce((t->>'recordLimitReached')::boolean,false) is false then extract(epoch from at_time-source_time) else null end)
    on conflict do nothing;
   end loop;
   clean_tables:=clean_tables||jsonb_build_array(t-'records');
  end loop;
  insert into automation.warehouse_observations(observed_at,state,document) values(at_time,'connected',(o-'tables')||jsonb_build_object('tables',clean_tables));
  update automation.warehouse_control set owner=null,lease_until=null,last_finished_at=clock_timestamp(),last_success_at=at_time,last_error_code=null where id;
  return jsonb_build_object('saved',true);
 end if;
 raise exception 'Invalid warehouse operation';
end $$;
revoke all on function automation.warehouse_probe(text,jsonb) from public,anon,authenticated;
-- Reuse the existing authenticated server worker transport, without new credentials.
do $$declare definition text;begin
 definition:=pg_get_functiondef('automation.worker(text,text,jsonb)'::regprocedure);
 if position('if operation=''baseline_ready''' in definition)=0 then raise exception 'Worker integration point changed';end if;
 definition:=replace(definition,'if operation=''baseline_ready''','if operation in (''warehouse_claim'',''warehouse_finish'') then return automation.warehouse_probe(operation,p);elsif operation=''baseline_ready''');
 execute definition;
end $$;
