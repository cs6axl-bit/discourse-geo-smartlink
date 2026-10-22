# discourse-geo-smartlink

Country smart links for affiliate offers that are split into one offer per country.

`https://<forum>/go/<key>` picks the visitor's country and redirects to that country's offer link:

1. the user's known country (`vsl_user_country`, matched from the `subid2` / `u` param),
2. the country of the click's IP (MaxMind-format DB, e.g. DB-IP Country Lite at `/shared/geo/dbip-country-lite.mmdb`),
3. the user's email domain (`.co.uk`, `bigpond.com`, ...),
4. `geo_smartlink_default_country`.

Links come from the Postgres table `offer_geo_links (key, country, url_template, active)`; a row with country `*`
is the fallback when the visitor's country has no version. URL templates may contain `{sub2}` (the `k` param or the
key), `{email_id}` and `{user_id}`. Every click is logged to `geo_smartlink_clicks`.

Both tables are created and filled outside the plugin (supshop repo `admin/giddyup/build-geo-links.mjs`) and need
`GRANT SELECT` (links) / `GRANT SELECT, INSERT` + sequence usage (clicks) for the `discourse` role.

## "Offer not available" page (0.2.0)

`/offer-unavailable?u=<urlsafe base64 of the clicked offer url>&r=geo|down|stuck&c=<category id>` tells the visitor
the offer can't be opened from their country (or is down / didn't load) and shows the best offers available there:
same category first, then by score (`offer_fallback_cards`). Country = click IP (DB-IP), then the user's known
country, then the email domain; an unknown country only gets offers without country limits. Each offer link carries
the original click's `email_id` / `subid2` (+ `sub4` / `sub5` on Everflow, `extclid` on ClickBank, `sub2=<key>-na`,
`na=1`) and goes through `/content` so the click is logged. Views are logged to `offer_unavailable_views`.

`GeoSmartlink.check_url(url, country)` reads `offer_link_rules` (network country rules, link health) and is used by
discourse-content-redirector >= 0.7.0 to send known dead ends (Everflow answers HTTP 204 = blank for blocked
countries) straight to this page. `/go/<key>` with no version for the visitor's country also lands here.
Tables are built by the supshop repo `admin/discourse/build-offer-fallback.mjs` (daily, after the link check).
