# frozen_string_literal: true

# name: discourse-geo-smartlink
# about: Country smart links at /go/<key> (offer_geo_links) plus the /offer-unavailable page: when an offer link would dead-end for the visitor (country blocked by the network, link down, or the click got stuck) the visitor sees the best offers available in their country, same category first. GeoSmartlink.check_url is used by discourse-content-redirector >= 0.7.0.
# version: 0.2.0
# authors: supshop
# url: https://github.com/cs6axl-bit/discourse-geo-smartlink

enabled_site_setting :geo_smartlink_enabled

after_initialize do
  require "base64"
  require "erb"

  module ::GeoSmartlink
    PLUGIN_NAME = "discourse-geo-smartlink"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace GeoSmartlink
    end

    class UnavailableEngine < ::Rails::Engine
      engine_name "geo_smartlink_unavailable"
      isolate_namespace GeoSmartlink
    end

    # email domain → country, for users with no known country and no IP result
    DOMAIN_CC = [
      [/\.uk\z|\A(btinternet\.com|sky\.com|talktalk\.net|virginmedia\.com|ntlworld\.com|blueyonder\.co\.uk)\z/, "GB"],
      [/\.au\z|\A(bigpond\.com|optusnet\.com\.au)\z/, "AU"],
      [/\.ca\z|\A(sasktel\.net|rogers\.com|telus\.net|bell\.net)\z/, "CA"],
      [/\.nz\z/, "NZ"], [/\.ie\z/, "IE"], [/\.de\z/, "DE"], [/\.at\z/, "AT"], [/\.fr\z/, "FR"], [/\.ch\z/, "CH"],
    ].freeze

    COUNTRY_NAMES = {
      "US" => "the United States", "CA" => "Canada", "GB" => "the United Kingdom", "AU" => "Australia",
      "NZ" => "New Zealand", "IE" => "Ireland", "DE" => "Germany", "AT" => "Austria", "CH" => "Switzerland",
      "FR" => "France", "ES" => "Spain", "IT" => "Italy", "NL" => "the Netherlands", "BE" => "Belgium",
      "SE" => "Sweden", "NO" => "Norway", "DK" => "Denmark", "FI" => "Finland", "PT" => "Portugal", "PL" => "Poland",
      "IL" => "Israel", "IN" => "India", "PH" => "the Philippines", "ZA" => "South Africa", "MX" => "Mexico",
      "BR" => "Brazil", "SG" => "Singapore", "MY" => "Malaysia", "JP" => "Japan", "AE" => "the UAE",
    }.freeze

    # Everflow tracking links: one ruleset per offer, the uid / sub params don't change it
    EVERFLOW_HOST = /\A(www\.)?(gu-ecom|dsw0trk|trk2dkt)\.com\z/

    # MaxMind-format IP → country DB (DB-IP Country Lite, CC BY 4.0). Reloaded when the file changes.
    def self.mmdb
      path = SiteSetting.geo_smartlink_mmdb_path.to_s
      return nil if path.blank? || !File.exist?(path)
      mtime = File.mtime(path)
      if @mmdb.nil? || @mmdb_mtime != mtime
        @mmdb = MaxMindDB.new(path)
        @mmdb_mtime = mtime
      end
      @mmdb
    rescue => e
      Rails.logger.warn("[#{PLUGIN_NAME}] mmdb: #{e.class}: #{e.message}")
      nil
    end

    def self.ip_country(ip)
      db = mmdb
      return nil unless db && ip.present?
      r = db.lookup(ip.to_s)
      r.found? ? r.country.iso_code.to_s.upcase.presence : nil
    rescue
      nil
    end

    # owner data: BG phone > LogiCall > dropship (merged by the supshop repo, admin/reports/merge-user-country.mjs)
    def self.user_country(user_id)
      return nil unless user_id
      DB.query_single("SELECT country_code FROM vsl_user_country WHERE user_id = :id LIMIT 1", id: user_id).first.to_s.strip.upcase.presence
    rescue
      nil
    end

    def self.domain_country(user_id)
      return nil unless user_id
      em = DB.query_single(%(SELECT email FROM user_emails WHERE user_id = :id AND "primary" LIMIT 1), id: user_id).first.to_s.downcase
      dom = em.split("@", 2)[1].to_s
      DOMAIN_CC.each { |re, cc| return cc if re.match?(dom) }
      nil
    rescue
      nil
    end

    # Country for "will this click work": the network decides by the click IP, so IP first.
    # Returns [country or nil, source].
    def self.visitor_country(request, user_id = nil)
      if (c = ip_country(request.remote_ip)) then return [norm_cc(c), "ip"] end
      if (c = user_country(user_id)) then return [norm_cc(c), "user"] end
      if (c = domain_country(user_id)) then return [norm_cc(c), "domain"] end
      [nil, "unknown"]
    end

    def self.norm_cc(c)
      c = c.to_s.strip.upcase
      c == "UK" ? "GB" : c.presence
    end

    def self.csv_set(s)
      s.to_s.split(",").map { |x| norm_cc(x) }.compact
    end

    # allowed NULL = anywhere; denied always wins; unknown country only passes an unrestricted list
    def self.allowed_in?(allowed, denied, cc)
      return false if cc && csv_set(denied).include?(cc)
      return true if allowed.nil?
      return false if cc.nil?
      csv_set(allowed).include?(cc)
    end

    def self.query_params(url)
      Rack::Utils.parse_query(URI.parse(url.to_s).query.to_s)
    rescue
      {}
    end

    # forum link plugins append email_id=, subid2 / aff_sub2 = "<user>-<topic>-<email_id>", sub4 / sub5 (Everflow)
    def self.ids_from_url(url)
      q = query_params(url)
      packed = (q["subid2"].presence || q["aff_sub2"].presence).to_s.split("-")
      uid = (q["sub5"].presence || packed[0]).to_s
      eid = (q["email_id"].presence || q["sub4"].presence || q["extclid"].presence || packed[2]).to_s
      [uid.match?(/\A\d{1,10}\z/) ? uid.to_i : nil, eid.match?(/\A[0-9A-Za-z_-]{1,100}\z/) ? eid : nil]
    end

    def self.user_id_from_url(url)
      ids_from_url(url)[0]
    end

    # Would a click on url dead-end for a visitor in cc? Rules: Postgres offer_link_rules (supshop repo
    # admin/discourse/build-offer-fallback.mjs), every row whose match_prefix starts the url.
    # → { blocked: true/false, reason: "geo" | "down", category_id:, label: }
    def self.check_url(url, cc)
      rules = DB.query("SELECT * FROM offer_link_rules WHERE starts_with(:u, match_prefix)", u: url.to_s)
      return { blocked: false, category_id: nil } if rules.empty?
      cat = rules.sort_by { |r| -r.match_prefix.length }.map(&:category_id).compact.first
      if (bad = rules.find { |r| !r.healthy })
        return { blocked: true, reason: "down", category_id: cat, label: bad.label }
      end
      if cc
        ship = SiteSetting.geo_smartlink_unavailable_use_ship_lists
        rules.each do |r|
          hard = !r.hard_allowed.nil? || r.hard_denied.present?
          if hard && !allowed_in?(r.hard_allowed, r.hard_denied, cc)
            return { blocked: true, reason: "geo", category_id: cat, label: r.label }
          end
          soft = !r.ship_allowed.nil? || r.ship_denied.present?
          if ship && soft && !allowed_in?(r.ship_allowed, r.ship_denied, cc)
            return { blocked: true, reason: "geo", category_id: cat, label: r.label }
          end
        end
      end
      { blocked: false, category_id: cat }
    rescue => e
      Rails.logger.warn("[#{PLUGIN_NAME}] check_url: #{e.class}: #{e.message}")
      { blocked: false, category_id: nil }
    end

    def self.b64(s)
      Base64.urlsafe_encode64(s.to_s, padding: false)
    end

    def self.unb64(s)
      return nil if s.blank? || s.to_s.length > 4096
      str = s.to_s.strip.tr("-_", "+/")
      str += "=" * ((4 - str.length % 4) % 4)
      d = Base64.decode64(str).force_encoding("UTF-8")
      d.valid_encoding? && d.match?(%r{\Ahttps?://}i) ? d : nil
    rescue
      nil
    end

    # where to send a visitor whose click on orig_url can't work
    def self.unavailable_path(orig_url, reason, category_id = nil)
      q = +"u=#{b64(orig_url)}&r=#{ERB::Util.url_encode(reason.to_s)}"
      q << "&c=#{category_id.to_i}" if category_id
      "#{Discourse.base_path}/offer-unavailable?#{q}"
    end

    def self.unavailable_enabled?
      SiteSetting.geo_smartlink_enabled && SiteSetting.geo_smartlink_unavailable_enabled
    rescue
      false
    end

    # same offer = the card's own link starts the url, same Everflow offer path, or same ClickBank vendor
    def self.offer_identity(url)
      u = URI.parse(url.to_s)
      host = u.host.to_s.downcase
      return "ef:#{host.sub(/\Awww\./, "")}#{u.path.split("/")[0, 3].join("/")}" if EVERFLOW_HOST.match?(host)
      return "cb:#{query_params(url)["vendor"].to_s.downcase}" if host == "hop.clickbank.net"
      return "go:#{u.path.split("/")[2]}" if u.path.start_with?("/go/")
      "url:#{url.to_s.split("&email_id=").first}"
    rescue
      "url:#{url}"
    end
  end

  # Inherits ActionController::Base (NOT ApplicationController): no login / session / CSRF layers, like /lp pages.
  class ::GeoSmartlink::GoController < ::ActionController::Base
    def go
      return redirect_to(SiteSetting.geo_smartlink_fallback_url.presence || "/", allow_other_host: true) unless SiteSetting.geo_smartlink_enabled

      key = params[:key].to_s
      # ids the forum's link plugins append to every email link: email_id=, subid2 / aff_sub2 = "<user>-<topic>-<email_id>"
      packed = (params[:subid2].presence || params[:aff_sub2].presence).to_s.split("-")
      email_id = (params[:email_id].presence || params[:extclid].presence || packed[2]).to_s
      email_id = "" unless email_id.match?(/\A[0-9A-Za-z_-]{1,100}\z/)
      uid = (params[:u].presence || packed[0]).to_s
      user_id = uid.match?(/\A\d{1,10}\z/) ? uid.to_i : nil
      sub2 = params[:k].to_s.presence || key
      sub2 = key unless sub2.match?(/\A[0-9A-Za-z_.-]{1,100}\z/)

      links = DB.query("SELECT country, url_template FROM offer_geo_links WHERE key = :k AND active", k: key)
        .each_with_object({}) { |r, h| h[r.country.to_s.strip.upcase] = r.url_template }

      uc = ::GeoSmartlink.user_country(user_id)
      ipc = ::GeoSmartlink.ip_country(request.remote_ip)
      dc = uc || ipc ? nil : ::GeoSmartlink.domain_country(user_id)
      chosen, source =
        if uc then [uc, "user"]
        elsif ipc then [ipc, "ip"]
        elsif dc then [dc, "domain"]
        else [SiteSetting.geo_smartlink_default_country.to_s.upcase, "default"]
        end
      chosen = "GB" if chosen == "UK"

      outcome = "match"
      tpl = links[chosen]
      if tpl.nil? && links["*"]
        tpl = links["*"]; outcome = "fallback"
      end
      if tpl.nil? && (lr = SiteSetting.geo_smartlink_last_resort_country.to_s.upcase.presence) && links[lr]
        tpl = links[lr]; outcome = "last_resort"
      end

      target =
        if tpl
          tpl.gsub("{sub2}", CGI.escape(sub2)).gsub("{email_id}", CGI.escape(email_id)).gsub("{user_id}", user_id.to_s)
        else
          outcome = links.empty? ? "unknown_key" : "no_version"
          if ::GeoSmartlink.unavailable_enabled?
            # no version for this country: the "not available in your country" page, same category first
            orig = "#{Discourse.base_url}/go/#{key}#{request.query_string.present? ? "?#{request.query_string}" : ""}"
            cat = ::GeoSmartlink.check_url(orig, nil)[:category_id]
            ::GeoSmartlink.unavailable_path(orig, "geo", cat)
          else
            SiteSetting.geo_smartlink_fallback_url.presence || "/"
          end
        end

      begin
        DB.exec(<<~SQL, key: key, uid: user_id, eid: email_id.presence, s2: sub2, uc: uc, ipc: ipc, ch: chosen, src: source, url: target, out: outcome)
          INSERT INTO geo_smartlink_clicks (key, user_id, email_id, sub2, user_country, ip_country, chosen_country, country_source, target_url, outcome)
          VALUES (:key, :uid, :eid, :s2, :uc, :ipc, :ch, :src, :url, :out)
        SQL
      rescue => e
        Rails.logger.warn("[#{::GeoSmartlink::PLUGIN_NAME}] log: #{e.class}: #{e.message}")
      end

      redirect_to target, allow_other_host: true, status: 302
    rescue => e
      Rails.logger.warn("[#{::GeoSmartlink::PLUGIN_NAME}] go #{params[:key]}: #{e.class}: #{e.message}")
      redirect_to(SiteSetting.geo_smartlink_fallback_url.presence || "/", allow_other_host: true)
    end
  end

  # /offer-unavailable?u=<urlsafe b64 of the original offer url>&r=geo|down|stuck&c=<category id>
  class ::GeoSmartlink::UnavailableController < ::ActionController::Base
    TRACK_KEYS = %w[email_id aff_sub2 subid2].freeze

    def show
      return redirect_to(SiteSetting.geo_smartlink_fallback_url.presence || "/", allow_other_host: true) unless ::GeoSmartlink.unavailable_enabled?

      orig = ::GeoSmartlink.unb64(params[:u])
      reason = params[:r].to_s[/\A[a-z_]{1,20}\z/] || "unknown"
      cat = params[:c].to_s[/\A\d{1,6}\z/]&.to_i
      user_id, email_id = orig ? ::GeoSmartlink.ids_from_url(orig) : [nil, nil]
      cc, cc_src = ::GeoSmartlink.visitor_country(request, user_id)
      cat ||= ::GeoSmartlink.check_url(orig, nil)[:category_id] if orig
      orig_id = orig ? ::GeoSmartlink.offer_identity(orig) : nil

      cards = DB.query("SELECT * FROM offer_fallback_cards ORDER BY score DESC NULLS LAST, vsl_id")
        .select { |c| ::GeoSmartlink.allowed_in?(c.allowed, c.denied, cc) }
        .reject { |c| orig_id && ::GeoSmartlink.offer_identity(c.link) == orig_id }
        .reject { |c| ::GeoSmartlink.check_url(c.link, cc)[:blocked] }
      same, other = cards.partition { |c| cat && c.category_id == cat }
      limit = SiteSetting.geo_smartlink_unavailable_max_cards.to_i.clamp(1, 24)
      shown = (same + other).first(limit)

      begin
        DB.exec(<<~SQL, r: reason, cc: cc, src: cc_src, uid: user_id, eid: email_id, o: orig.to_s[0, 2000], cat: cat, s: shown.map(&:vsl_id).join(","))
          INSERT INTO offer_unavailable_views (reason, country, country_source, user_id, email_id, orig_url, category_id, shown)
          VALUES (:r, :cc, :src, :uid, :eid, :o, :cat, :s)
        SQL
      rescue => e
        Rails.logger.warn("[#{::GeoSmartlink::PLUGIN_NAME}] unavailable log: #{e.class}: #{e.message}")
      end

      response.headers["Cache-Control"] = "no-store"
      render html: page_html(reason, cc, shown, orig, user_id, email_id).html_safe
    rescue => e
      Rails.logger.warn("[#{::GeoSmartlink::PLUGIN_NAME}] unavailable: #{e.class}: #{e.message}")
      redirect_to(SiteSetting.geo_smartlink_fallback_url.presence || "/", allow_other_host: true)
    end

    private

    # card link + the original click's tracking ids, wrapped in /content so the click is logged like any email click
    def card_href(link, orig, user_id, email_id)
      q = orig ? ::GeoSmartlink.query_params(orig) : {}
      u = URI.parse(link)
      host = u.host.to_s.downcase
      cur = Rack::Utils.parse_query(u.query.to_s)
      add = TRACK_KEYS.each_with_object({}) { |k, h| h[k] = q[k] if q[k].present? }
      if ::GeoSmartlink::EVERFLOW_HOST.match?(host)
        add["sub4"] = email_id if email_id
        add["sub5"] = user_id.to_s if user_id
        add["sub2"] = "#{cur["sub2"]}-na" if cur["sub2"].present?
      end
      add["extclid"] = email_id if host == "hop.clickbank.net" && email_id && cur["extclid"].blank?
      add["na"] = "1"
      u.query = Rack::Utils.build_query(cur.merge(add))
      target = u.to_s
      if (SiteSetting.content_redirector_enabled rescue false)
        "#{Discourse.base_path}/content?u=#{::GeoSmartlink.b64(target)}"
      else
        target
      end
    rescue
      link
    end

    def page_html(reason, cc, cards, orig, user_id, email_id)
      h = ->(s) { ERB::Util.html_escape(s.to_s) }
      where = ::GeoSmartlink::COUNTRY_NAMES[cc] || "your country"
      title, intro =
        case reason
        when "down"
          ["This offer is not available right now", "Sorry, the offer you clicked is currently unavailable."]
        when "stuck"
          ["This offer didn't load", "Sorry, the offer you clicked didn't open. It may not be available in #{where}."]
        else
          ["This offer isn't available in #{where}", "Sorry, the offer you clicked can't be ordered from #{where}."]
        end
      intro += cards.any? ? " Here are popular offers that are available to you:" : ""
      forum = "#{Discourse.base_url}/"
      cards_html = cards.map do |c|
        href = h.(card_href(c.link, orig, user_id, email_id))
        img = c.image_url.present? ? %(<a class="img" href="#{href}" rel="nofollow noopener"><img src="#{h.(c.image_url)}" alt="#{h.(c.source)}" loading="lazy"></a>) : ""
        <<~CARD
          <div class="card">
            #{img}
            <div class="body">
              <div class="cat">#{h.(c.category_name)}</div>
              <div class="name">#{h.(c.source)}</div>
              <div class="head">#{h.(c.headline)}</div>
              <div class="blurb">#{h.(c.blurb)}</div>
              <a class="btn" href="#{href}" rel="nofollow noopener">Learn more</a>
            </div>
          </div>
        CARD
      end.join
      <<~HTML
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="robots" content="noindex, nofollow">
            <title>#{h.(title)} | #{h.(SiteSetting.title)}</title>
            <style>
              :root { --bg:#f6f7f9; --card:#fff; --text:#1f2328; --muted:#5b6470; --line:rgba(0,0,0,.1); --accent:#0a7f5a; }
              @media (prefers-color-scheme: dark) { :root { --bg:#15181c; --card:#1e2227; --text:#e8eaed; --muted:#a0a7b1; --line:rgba(255,255,255,.12); --accent:#2fbf8a; } }
              * { box-sizing: border-box; }
              body { margin:0; background:var(--bg); color:var(--text); font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif; }
              .wrap { max-width:1000px; margin:0 auto; padding:24px 16px 40px; }
              .top { font-size:15px; margin-bottom:18px; } .top a { color:var(--accent); text-decoration:none; font-weight:600; }
              h1 { font-size:26px; line-height:1.25; margin:0 0 10px; }
              .intro { font-size:18px; line-height:1.5; color:var(--muted); margin:0 0 22px; }
              .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:16px; }
              .card { background:var(--card); border:1px solid var(--line); border-radius:12px; overflow:hidden; display:flex; flex-direction:column; }
              .card .img img { display:block; width:100%; aspect-ratio:16/9; object-fit:cover; }
              .body { padding:14px 16px 16px; display:flex; flex-direction:column; gap:6px; flex:1; }
              .cat { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); }
              .name { font-size:19px; font-weight:700; }
              .head { font-size:16px; font-weight:600; }
              .blurb { font-size:15px; line-height:1.45; color:var(--muted); flex:1; }
              .btn { margin-top:8px; align-self:flex-start; background:var(--accent); color:#fff; text-decoration:none; font-weight:600; padding:10px 18px; border-radius:8px; }
              .foot { margin-top:28px; font-size:15px; } .foot a { color:var(--accent); }
            </style>
          </head>
          <body>
            <div class="wrap">
              <div class="top"><a href="#{h.(forum)}">#{h.(SiteSetting.title)}</a></div>
              <h1>#{h.(title)}</h1>
              <p class="intro">#{h.(intro)}</p>
              <div class="grid">#{cards_html}</div>
              <p class="foot"><a href="#{h.(forum)}">Back to the forum</a></p>
            </div>
          </body>
        </html>
      HTML
    end
  end

  ::GeoSmartlink::Engine.routes.draw do
    get "/:key" => "go#go", constraints: { key: /[a-z0-9-]+/ }
  end

  ::GeoSmartlink::UnavailableEngine.routes.draw do
    get "/" => "unavailable#show"
  end

  Discourse::Application.routes.append do
    mount ::GeoSmartlink::Engine, at: "/go"
    # explicit name: isolate_namespace gives both engines the route name "geo_smartlink" (boot fails on the duplicate)
    mount ::GeoSmartlink::UnavailableEngine, at: "/offer-unavailable", as: "geo_smartlink_unavailable"
  end
end
