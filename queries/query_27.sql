WITH tags AS (
    SELECT domain, array_agg(tag) AS tags
    FROM 'scraped_ads_domain_tags.parquet'
    GROUP BY domain
),

image_urls_from_ads AS (
    SELECT 
        ad_id, unnest(list_transform(ad.snapshot.cards, x -> split_part(x.original_image_url , '?', 1))) AS image_url
        FROM 'scraped_ads.parquet'
),

ads_with_checksum as (
    SELECT DISTINCT
        image_urls_from_ads.ad_id, 
        scraped_ads_images.needle_checksum,
    FROM image_urls_from_ads
    LEFT JOIN 'scraped_ads_images.parquet' ON image_urls_from_ads.image_url = scraped_ads_images.url
    WHERE needle_checksum is not null
),

image_urls as (
    SELECT first(url || query order by added_at desc) as image_url, needle_checksum from 'scraped_ads_images.parquet'
    group by needle_checksum
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
        regexp_extract(ad.snapshot.link_url, 'http[s]?://([^/]+)/', 1) AS domain,
        ad.start_date,
        ad.end_date,
        ad.countries,
        ad.job_id,
        ad.run
    FROM 'scraped_ads.parquet' ad
)

SELECT 
    image_urls.image_url as "ad_image#image",
    ads_with_checksum.needle_checksum,
    array_agg({'url': 'https://www.facebook.com/ads/library?id=' || ads.ad_id, 'text': ads.ad_id}) as "ad_ids",
    
    list_distinct(array_agg(keywords_extracted.domain)) AS domains,
    count(*) AS "Total ads",
    SUM(CASE WHEN keywords_extracted.run = j.last_run THEN 1 ELSE 0 END) AS "Active ads",
    SUM(CASE WHEN keywords_extracted.run != j.last_run THEN 1 ELSE 0 END) AS "Inactive ads",
    ROUND((SUM(CASE WHEN keywords_extracted.run = j.last_run THEN 1 ELSE 0 END) * 100.0) / count(*), 2) AS "Percentage Active",
    list_distinct(flatten(array_agg(keywords_extracted.countries))) AS "countries#region",
    list_distinct(flatten(array_agg(tags.tags))) AS tags,
    MIN(keywords_extracted.start_date * 1000) AS "first_seen#ts",
    MAX(keywords_extracted.end_date * 1000) AS "last_seen#ts"    

FROM 'scraped_ads.parquet' ads
LEFT JOIN ads_with_checksum ON ads_with_checksum.ad_id = ads.ad_id
LEFT JOIN keywords_extracted ON keywords_extracted.ad_id = ads.ad_id
LEFT JOIN 'scraping_jobs.parquet' j ON keywords_extracted.job_id = j.id
LEFT JOIN tags ON keywords_extracted.domain ILIKE '%' || tags.domain || '%'
LEFT JOIN image_urls ON ads_with_checksum.needle_checksum = image_urls.needle_checksum
GROUP BY ads_with_checksum.needle_checksum, image_urls.image_url
