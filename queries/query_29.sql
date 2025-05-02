WITH tags AS (
    SELECT domain, array_agg(tag) AS tags
    FROM 'scraped_ads_domain_tags.parquet'
    GROUP BY domain
),

keywords_extracted AS (
    SELECT
        ad.*,
        replace(replace(
            coalesce(
                nullif(regexp_extract(ad.snapshot.link_url, '[?&](q|k|search_term|keyword)=([^&]*)', 2), ''),
                nullif(regexp_extract(ad.snapshot.link_url, 'https?://[^/]+/search/[^/]+/([^/?&]+)', 1), ''),
                regexp_extract(ad.snapshot.link_url, 'https?://[^/]+/topic/[^/]+/([^/?&]+)', 1)
            ), '+', ' '), '%20', ' ') AS keyword,
        regexp_extract(ad.snapshot.link_url, 'http[s]?://([^/]+)/', 1) AS domain
    FROM 'scraped_ads.parquet' ad
)

SELECT
    LOWER(ad.keyword),
    list_distinct(array_agg(ad.domain)) AS domains,
    count(*) AS "Total ads",
    SUM(CASE WHEN ad.run = j.last_run THEN 1 ELSE 0 END) AS "Active ads",
    SUM(CASE WHEN ad.run != j.last_run THEN 1 ELSE 0 END) AS "Inactive ads",
    ROUND((SUM(CASE WHEN ad.run = j.last_run THEN 1 ELSE 0 END) * 100.0) / count(*), 2) AS "Percentage Active",
    list_distinct(flatten(array_agg(ad.countries))) AS "countries#region",
    list_distinct(flatten(array_agg(tags.tags))) AS tags,
    MIN(ad.start_date * 1000) AS "first_seen#ts",
    MAX(ad.end_date * 1000) AS "last_seen#ts"
FROM keywords_extracted ad
LEFT JOIN 'scraping_jobs.parquet' j ON ad.job_id = j.id
LEFT JOIN tags ON ad.domain ILIKE '%' || tags.domain || '%'
WHERE ad.keyword IS NOT NULL AND ad.keyword != ''
AND 'rsoc' = ANY(tags.tags)
GROUP BY LOWER(ad.keyword)
ORDER BY "Active ads" DESC