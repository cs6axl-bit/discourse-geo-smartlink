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
