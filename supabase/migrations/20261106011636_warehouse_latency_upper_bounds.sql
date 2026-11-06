-- Sampling can omit records during high activity. A measured source-to-first-read
-- interval is still a valid upper bound for each observed event, never a claim
-- that every event was captured or that the warehouse published it at that instant.
do $$declare definition text;needle text:=' and coalesce((t->>''recordLimitReached'')::boolean,false) is false';begin
 definition:=pg_get_functiondef('automation.warehouse_probe(text,jsonb)'::regprocedure);
 if position(needle in definition)=0 then raise exception 'Warehouse latency integration point changed';end if;
 execute replace(definition,needle,'');
end $$;
comment on column automation.warehouse_record_versions.detection_latency_seconds is 'Source event to first observed read: an upper bound on warehouse visibility latency for this sampled version. Historical baseline, unknown source timezone, future source dates and timestamps predating monitor startup are excluded. Not a notification eligibility signal.';
