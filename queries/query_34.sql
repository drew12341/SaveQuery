
WITH all_seen_times as (
   select distinct on (ad_id, job_id, seen_at) ad_id, job_id, seen_at as added_at
   from 'scraped_ads_seen.parquet'
),

last_seen as (
    select distinct on (ad_id) ad_id, added_at as last_seen
    from all_seen_times
    order by added_at desc
),

job_processed_last as (
   select distinct on (job_id) job_id, run, processed_at from 'scraping_runs.parquet'
   where processed_at is not null and parsed_at is not null
   order by run desc
)


SELECT 
    keyword, 
    tags.tag, 
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
                title:  list_aggregate(coalesce(nullif(list_distinct(list_transform(ad.snapshot.cards, x -> x.title)), []), [ad.snapshot.title]), 'string_agg'),
                description: list_aggregate(coalesce(nullif(list_distinct(list_transform(ad.snapshot.cards, x -> x.link_description)), []), [ad.snapshot.link_description]), 'string_agg'),
                body: list_aggregate(coalesce(nullif(list_distinct(list_transform(ad.snapshot.cards, x -> x.body)), []), [ad.snapshot.body.text]), 'string_agg'),
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
                        countries: sub.countries,
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


FROM (
    SELECT
        ad.*,
       
        replace(replace(
        coalesce(
            nullif(regexp_extract(ad.snapshot.link_url, '[?&](q|k|search_term|keyword)=([^&]*)', 2), ''),
            nullif(regexp_extract(ad.snapshot.link_url, 'https?://[^/]+/search/[^/]+/([^/?&]+)', 1), ''),
            regexp_extract(ad.snapshot.link_url, 'https?://[^/]+/topic/[^/]+/([^/?&]+)', 1)
        ), '+', ' '), '%20', ' ') AS keyword,
        
        regexp_extract(ad.snapshot.link_url, 'http[s]?://([^/]+)/', 1) AS domain,

        ROW_NUMBER() OVER (PARTITION BY keyword, domain ORDER BY ad.start_date ASC) AS rn
   FROM 'scraped_ads.parquet' ad
   WHERE keyword IS NOT NULL AND keyword != ''
) sub
LEFT JOIN  'scraped_ads_domain_tags.parquet' tags ON tags.domain = sub.domain
left join last_seen on last_seen.ad_id = sub.ad_id
left join job_processed_last on job_processed_last.job_id = sub.job_id

WHERE rn = 1
AND floor((processed_at - coalesce(last_seen.last_seen, sub.run)) / 1000 / 60 / 60) <= 24