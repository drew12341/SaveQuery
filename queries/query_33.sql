
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
    to_json(ad) as '#ad#ui',

    json({
  actions: [

    json({
        id: 'data',
        object: {
            object: json({
                pixel_id: '800476344861254',
                page_id: '270515366148083',
                account_id: '450465504361734',
                base_url: 'https://top.protipstoday.net/search/215/',
                custom_css: '',
                end_time: (datetrunc('hour', now()::timestamp) + interval 1 month)::timestamptz,
                keyword: keyword,
                title: title,
                description: "link_description#hide",
                body: "body#hide",
                image_url: list_aggregate(coalesce(nullif(list_distinct(list_transform(ad.snapshot.cards, x -> x.original_image_url)), []), nullif(list_distinct(list_transform(ad.snapshot.images, x -> x.original_image_url)), [])), 'first')
            })::text
        }
    }),

    json({
        id: 'ad_extract',
        open_ai_text: {
        prompt: $$Generate variations of body, title and description. You need to create a variation of the ad based on the text - rephrase the text, but keep in mind that this is an ad. Body: .{ .data.body } Title: .{ .data.title } Description: .{ .data.description }. You need to return a JSON object. Only return the JSON objects. Your response must be in the following format: { "body": "Body text", "title: "Title text", "description": "Description text" }$$,
        model: 'gpt-4o'
        }
    }),

    json({
        id: 'image_extract',
        open_ai_text: {
        prompt: $$From the following ad, identify the following text elements if they exist: headline, subheadline, button. You need to create a variation of the ad based on the identified text - rephrase the text, but keep in mind that this is an ad. Also keep numbers the same. Also create a prompt of less than 1000 characters to create a version of this image (make sure the image does not contain any text). You need to return a JSON object. Only return the JSON objects. Your response must be in the following format:   { "prompt": "Prompt to create a version of this image. Ignore any text, do not write any part of the prompt to create text. Start your reply with - Create a", "headline": "Headline text", "subheadline": "Subheadline text", "button": "Button text" }$$,
        model: 'gpt-4o',
        image_source: '.{ .data.image_url }'
        }
    }),

    json({
        id: 'image',
        gen_image: {
        stable_difussion: {
            prompt: '.{ .image_extract.prompt }',
            gen_image_sd_core: {
                aspect_ratio: '16:9'
            }
        }
        }
    }),

    json({
        id: 'generated_ad',
        generate_ad: {
        html: $$
        <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Template 3</title>
        <style>
          body { margin: 0; width: 1080px; height: 1080px; display: flex; flex-direction: column; align-items: center; font-family: Arial, sans-serif; overflow: hidden; }
          .headline-container { width: 90%; margin:30px 0; text-align: center; flex-shrink: 0; height: 300px; display: flex; justify-content: center; align-items: center; }
          .headline { font-size: 90px; line-height: 1.1; word-wrap: break-word; overflow: hidden; }
          .image-container { width: 90%; flex-grow: 1; display: flex; justify-content: center; align-items: center; }
          .image-container img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 20px; }
          .button-container { width: 90%; text-align: center; flex-shrink: 0; height: 150px; display: flex; justify-content: center; align-items: center; }
          .button button { padding: 20px 40px; font-size: 36px; background-color: #007BFF; color: white; border: none; border-radius: 10px; cursor: pointer; }
        </style>
        .{ .data.custom_css } <!-- Inject custom CSS here -->
      </head>
      <body>
        <div class="headline-container">
          <div class="headline">.{ .image_extract.headline }</div>
        </div>
        <div class="image-container">
          <img src=".{ .image.image }" alt="Ad Image">
        </div>
        <div class="button-container">
          <div class="button">
            <button>.{ .image_extract.button }</button>
          </div>
        </div>
        <script>
          (function() {
            // Function to scale the text of an element to fit its container
            function scaleTextToFit(element, containerHeight, maxFontSize, minFontSize = 20) {
              let fontSize = maxFontSize;
              element.style.fontSize = fontSize + 'px';

              while (element.scrollHeight > containerHeight && fontSize > minFontSize) {
                fontSize -= 1;
                element.style.fontSize = fontSize + 'px';
              }
            }

            // Scale the headline to fit
            const headlineElement = document.querySelector('.headline');
            const headlineContainerHeight = headlineElement.parentElement.clientHeight;
            scaleTextToFit(headlineElement, headlineContainerHeight, 120); // max font size of 120px

          })();
        </script>
      </body>
    </html>
        $$
        }
    }),

    json({
        id: 'campaign',
        facebook_post: {
            endpoint: 'act_.{ .data.account_id }/campaigns',
            params: json({
               name: 'Campaign - .{ .data.keyword }',
               objective: 'OUTCOME_LEADS',
               special_ad_categories: [],
               status: 'PAUSED'
            })::text
        }
    }),

    json({
        id: 'adset',
        facebook_post: {
            endpoint: 'act_.{ .data.account_id }/adsets',
            params: json({
                attribution_spec: [
                    {
                        event_type: 'CLICK_THROUGH',
                        window_days: 7
                    },
                    {
                        event_type: 'VIEW_THROUGH',
                        window_days: 1
                    }
                ],
                campaign_id: '.{ .campaign.id }',
                bid_strategy: 'LOWEST_COST_WITHOUT_CAP',
                billing_event: 'IMPRESSIONS',
                lifetime_budget: 90000,
                end_time: '.{ .data.end_time }',
                name: 'Adset',
                promoted_object: {
                    custom_event_type: 'SEARCH',
                    pixel_id: '.{ .data.pixel_id }'
                },
                targeting: {
                    geo_locations: {
                        countries: ad.countries,
                    },
                    device_platforms: ['mobile'],
                    targeting_automation: {
                        advantage_audience: 1
                    }
                }
            })::text
        }
    }),

    json({
        id: 'ad',
        facebook_post: {
            endpoint: 'act_.{ .data.account_id }/ads',
            params: json({
                adset_id: '.{ .adset.id }',
                creative: {
                    degrees_of_freedom_spec: {
                        creative_features_spec: {
                            standard_enhancements: {
                                enroll_status: 'OPT_OUT'
                            }
                        }
                    },
                    object_story_spec: {
                        link_data: {
                            call_to_action: {
                                type: 'LEARN_MORE'
                            },
                            link: '.{ .data.base_url }.{ .data.keyword }/?t=1&chnm=FB_US&chnm2=%7B%7Bcampaign.id%7D%7D&chnm3=%7B%7Badset.id%7D%7D&fbclid=fbclid',
                            message: '.{ jsonEscape .data.body }',
                            name: '.{ .data.title }',
                            description: '.{ .data.description | default "" }',
                            picture: '.{ .generated_ad.image }'
                        },
                        page_id: '.{ .data.page_id }'
                    }
                },
                name: 'Ad',
                status: 'ACTIVE'
            })::text
        }
    })
  ]
}) as "create_ads#action"




from 'scraped_ads.parquet' ad
left join 'scraping_jobs.parquet' j on ad.job_id = j.id
left join tags on regexp_extract(ad.snapshot.link_url, 'http[s]?://([^/]+)/', 1) ilike '%' || tags.domain || '%'
left join ad_checksums on ad_checksums.ad_id = ad.ad_id
left join job_processed_last on job_processed_last.job_id = ad.job_id
left join all_seen_agg on all_seen_agg.ad_id = ad.ad_id
left join all_processed on all_processed.job_id = all_seen_agg.job_id
left join last_seen on last_seen.ad_id = ad.ad_id
WHERE "last_seen_hours_ago#hide" <= 24