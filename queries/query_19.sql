
select job_id, run as "run#ts", started_at as "started_at#ts", processed_at as "processed_at#ts", parsed_at as "parsed_at#ts" from 'scraping_runs.parquet' order by run desc
limit 100