
with tags as (
    select domain, array_agg(tag) as tags
    from 'scraped_ads_domain_tags.parquet'
    group by domain
)

select [HELLO TEST]
   
replace(replace(
        coalesce(
            nullif(regexp_extract(ad.snapshot.link_url, '[?&](q|k|search_term|keyword)=([^&]*)', 2), ''),
            nullif(regexp_extract(ad.snapshot.link_url, 'https?://[^/]+/search/[^/]+/([^/?&]+)', 1), ''),
            regexp_extract(ad.snapshot.link_url, 'https?://[^/]+/topic/[^/]+/([^/?&]+)', 1)
        ), '+', ' '), '%20', ' ') as keyword,
    count(*) as "Total ads",
    SUM(CASE WHEN ad.run = j.last_run THEN 1 ELSE 0 END) AS "Active ads",
    SUM(CASE WHEN ad.run != j.last_run THEN 1 ELSE 0 END) AS "Inactive ads",
    ROUND((SUM(CASE WHEN ad.run = j.last_run THEN 1 ELSE 0 END) * 100.0) / count(*), 2) AS "Percentage Active",
    
    list_distinct(flatten(array_agg(ad.countries))) as "countries#region",
    list_distinct(flatten(array_agg(tags.tags))) as tags
from 'scraped_ads.parquet' ad
left join 'scraping_jobs.parquet' j on ad.job_id = j.id
left join tags on regexp_extract(ad.snapshot.link_url, 'http[s]?://([^/]+)/', 1) ilike '%' || tags.domain || '%'
where keyword is not null and keyword != ''
group by keyword
order by "Total ads" desc