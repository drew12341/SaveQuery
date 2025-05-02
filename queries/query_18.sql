with runs as (
select 
  distinct on (job_id) job_id, run, last_retry_reason, started_at as "Started At#ts", country as "Processing country", estimated_count as "Ads left to scrape", floor((estimated_count / 30) * last_page_processed_time_ms / 1000 / 60) as "Estimated completion time (mins)", tries,    
 list_transform(from_json(error, '[{"err":"string","ts":"string"}]'), 
    x -> case when x.err = 1 then 'Blocked' when x.err = 2 then 'Search error' when x.err = 3 then 'Proxy error' when x.err = 4 then 'File not exists' when x.err = 5 then 'Other error' end || ' at ' || (make_timestamptz(x.ts::BIGINT*1000) AT TIME ZONE 'Pacific/Auckland')) as "Errors" 
  
from 'scraping_runs_countries.parquet' c 
where processed_at is null
order by started_at asc)

select * from runs