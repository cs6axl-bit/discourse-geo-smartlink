# frozen_string_literal: true

# name: discourse-geo-smartlink
# about: Country smart links at /go/<key>. Picks the visitor's country (known user country > country of the click's IP > email domain > default) and redirects to that country's offer link from the Postgres table offer_geo_links. Logs every click to geo_smartlink_clicks.
# version: 0.1.0
# authors: supshop
# url: https://github.com/cs6axl-bit/discourse-geo-smartlink

enabled_site_setting :geo_smartlink_enabled

after_initialize do
  module ::GeoSmartlink
    PLUGIN_NAME = "discourse-geo-smartlink"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace GeoSmartlink
    end

    # email domain → country, for users with no known country and no IP result
    DOMAIN_CC = [
      [/\.uk\z|\A(btinternet\.com|sky\.com|talktalk\.net|virginmedia\.com|ntlworld\.com|blueyonder\.co\.uk)\z/, "GB"],
      [/\.au\z|\A(bigpond\.com|optusnet\.com\.au)\z/, "AU"],
      [/\.ca\z|\A(sasktel\.net|rogers\.com|telus\.net|bell\.net)\z/, "CA"],
      [/\.nz\z/, "NZ"], [/\.ie\z/, "IE"], [/\.de\z/, "DE"], [/\.at\z/, "AT"], [/\.fr\z/, "FR"], [/\.ch\z/, "CH"],
    ].freeze

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
          SiteSetting.geo_smartlink_fallback_url.presence || "/"
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

  ::GeoSmartlink::Engine.routes.draw do
    get "/:key" => "go#go", constraints: { key: /[a-z0-9-]+/ }
  end

  Discourse::Application.routes.append do
    mount ::GeoSmartlink::Engine, at: "/go"
  end
end
