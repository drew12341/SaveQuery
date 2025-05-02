[[ template "All scraped ads" ]]
WHERE ad.run = j.last_run
and ad.start_date < epoch(now() - INTERVAL '2 weeks')