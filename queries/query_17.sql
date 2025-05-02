
with tags as (
    select domain, array_agg(tag) as tags
    from 'scraped_ads_domain_tags.parquet'
    group by domain
),

unnested_images as (
   select ad_id as ad_id, 
   unnest(list_transform(ad.snapshot.cards, x ->  split_part(x.original_image_url, '?', 1))) as image
   from 'scraped_ads.parquet'
),

ad_checksums as (
   select unnested_images.ad_id, sum(DISTINCT needle_checksum) as hashes_sum, array_agg(DISTINCT needle_checksum) as hashes_list
   from unnested_images
   left join 'scraped_ads_images.parquet' hashes on 'https://' || hashes.url = image
   where hashes.url is not null
   group by ad_id
),

job_processed_last as (
   select distinct on (job_id) job_id, run, processed_at from 'scraping_runs.parquet'
   where processed_at is not null and parsed_at is not null
   order by run desc
),

all_seen_times as (
   select distinct on (ad_id, job_id, seen_at) ad_id, job_id, seen_at as added_at
   from 'scraped_ads_seen.parquet'
),

last_seen as (
   select distinct on (ad_id) ad_id, added_at as last_seen
   from all_seen_times
   order by added_at desc
),

all_seen_agg as (
    select 
    ad_id,
    job_processed_last.job_id,
    array_agg(distinct extract('hour' from epoch_ms(added_at)) order by extract('hour' from epoch_ms(added_at)) asc) as hours_seen
    from all_seen_times
    left join job_processed_last on job_processed_last.job_id = all_seen_times.job_id
    where (job_processed_last.processed_at - added_at) / 1000  / 60 / 60 <= 24
    group by ad_id, job_processed_last.job_id
),


all_processed as (
   select all_runs.job_id, 
      list_sort(list_distinct(flatten(array_agg(list_distinct(list_transform(list_append(generate_series(epoch_ms(started_at), epoch_ms(all_runs.processed_at), interval '1' hour), epoch_ms(all_runs.processed_at)), x -> extract('hour' from x))))))) as hours_scraped
   from 'scraping_runs.parquet' all_runs
   left join job_processed_last on job_processed_last.job_id = all_runs.job_id
   where (job_processed_last.processed_at - all_runs.processed_at) / 1000  / 60 / 60 <= 24
   group by all_runs.job_id
)

select
    ad.ad_id as "ad_id#ad_id",
    list_aggregate(coalesce(nullif(list_distinct(list_transform(ad.snapshot.cards, x -> x.body)), []), [ad.snapshot.body.text]), 'string_agg') as "body#hide",
    list_aggregate(coalesce(nullif(list_distinct(list_transform(ad.snapshot.cards, x -> x.link_description)), []), [ad.snapshot.link_description]), 'string_agg') as "link_description#hide",
    list_aggregate(coalesce(nullif(list_distinct(list_transform(ad.snapshot.cards, x -> x.link_url)), []), [ad.snapshot.link_url]), 'string_agg') as "link_url#hide",
    list_aggregate(coalesce(nullif(list_distinct(list_transform(ad.snapshot.cards, x -> x.original_image_url)), []), nullif(list_distinct(list_transform(ad.snapshot.images, x -> x.original_image_url)), [])), 'string_agg') as "image_url#export",
replace(replace(
        coalesce(
            nullif(regexp_extract(ad.snapshot.link_url, '[?&](q|k|search_term|keyword|s)=([^&]*)', 2), ''),
            nullif(regexp_extract(ad.snapshot.link_url, 'https?://[^/]+/search/[^/]+/([^/?&]+)', 1), ''),
            regexp_extract(ad.snapshot.link_url, 'https?://[^/]+/topic/[^/]+/([^/?&]+)', 1)
        ), '+', ' '), '%20', ' ') as keyword,
    j.query as job,
    list_aggregate(coalesce(nullif(list_distinct(list_transform(ad.snapshot.cards, x -> x.title)), []), [ad.snapshot.title]), 'string_agg') as "title",
    ad.snapshot.link_url as url,
    hashes_sum,
    hashes_list,
    ad.start_date * 1000 as "start_date#ts",
    ad.end_date - coalesce(ad.start_date, 0) as 'days runnings#secs',
    processed_at as "last_scraped#ts",
    floor((processed_at - coalesce(last_seen.last_seen, ad.run)) / 1000 / 60 / 60) as "last_seen_hours_ago#hide",
    hours_scraped,
    case when len(hours_seen) = 24 then 'ALL' else list_aggregate(hours_seen, 'string_agg', ', ') end as hours_seen,
    ad.countries as "countries#region",
    tags.tags as tags,
    to_json(ad) as '#ad#ui'
from 'scraped_ads.parquet' ad
left join 'scraping_jobs.parquet' j on ad.job_id = j.id
left join tags on regexp_extract(ad.snapshot.link_url, 'http[s]?://([^/]+)/', 1) ilike '%' || tags.domain || '%'
left join ad_checksums on ad_checksums.ad_id = ad.ad_id
left join job_processed_last on job_processed_last.job_id = ad.job_id
left join all_seen_agg on all_seen_agg.ad_id = ad.ad_id
left join all_processed on all_processed.job_id = all_seen_agg.job_id
left join last_seen on last_seen.ad_id = ad.ad_id