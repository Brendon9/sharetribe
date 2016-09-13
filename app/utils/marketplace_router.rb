module MarketplaceRouter
  module DataTypes

    LIKE_HASH = ->(v) {
      return if v.nil?

      unless v.respond_to?(:[])
        {code: :must_be_hash_like, msg: "Value must be like hash (i.e. responds to :[])"}
      end
    }

    Request = EntityUtils.define_builder(
      [:host, :string, :mandatory],
      [:protocol, :string, one_of: ["http://", "https://"]],
      [:fullpath, :string, :mandatory],
      [:port_string, :string, :optional, default: ""],
      [:headers, :mandatory, validate_with: LIKE_HASH]
    )

    Community = EntityUtils.define_builder(
      [:use_domain, :bool, :mandatory],
      [:deleted, :bool, :mandatory],
      [:closed, :bool, :mandatory],
      [:domain, :string, :optional],
      [:ident, :string, :mandatory]
    )

    Path = EntityUtils.define_builder(
      [:url, :string, :optional],
      [:route_name, :symbol, :optional]
    )

    Paths = EntityUtils.define_builder(
      [:community_not_found, :mandatory, entity: Path],
      [:new_community, :mandatory, entity: Path]
    )

    Configs = EntityUtils.define_builder(
      [:always_use_ssl, :bool, :mandatory],
      [:app_domain, :string, :mandatory]
    )

    Other = EntityUtils.define_builder(
      [:no_communities, :bool, :mandatory],
      [:community_search_status, one_of: [:found, :not_found, :skipped]]
    )

    # Target can be either URL or named route.
    # If URL, protocol and route_name are not needed
    # If named route, URL is not needed
    # Status should be included always
    Target = EntityUtils.define_builder(
      # Reason
      [:reason, :symbol, one_of: [
         :domain,          # Marketplace has a custom domain in use. Redirect to that domain.
         :no_domain,       # Marketplace has a custom domain but it's not in use. Redirect to subdomain.
         :deleted,         # Marketplace has been deleted
         :closed,          # Marketplace has been closed
         :not_found,       # Marketplace not found, but some marketplaces do exist
         :new_marketplace, # There are no marketplaces. Redirect to new marketplace page
         :https,           # Redirect to HTTPS
         :www_ident,       # Accessed marketplace with WWW and subdomain, e.g. www.mymarketplace.sharetribe.com
       ]],

      # Url
      [:url, :string, :optional],

      # Named route
      [:protocol, :string, :optional],
      [:route_name, :symbol, :optional],

      [:status, :symbol, :mandatory]
    )

    module_function

    def create_request(opts)
      Request.call(opts)
    end

    def create_community(opts)
      Community.call(opts)
    end

    def create_paths(opts)
      Paths.call(opts)
    end

    def create_configs(opts)
      Configs.call(opts)
    end

    def create_other(opts)
      Other.call(opts)
    end
  end

  module_function

  def needs_redirect(request:, community:, paths:, configs:, other:, &block)
    new_protocol = protocol(request: request, community: community, configs: configs)
    protocol_needs_redirect = request[:protocol] != "#{new_protocol}://"

    reason = redirect_reason(
      request: request,
      community: community,
      configs: configs,
      other: other,
      protocol_needs_redirect: protocol_needs_redirect)

    if reason
      target = redirect_target(
        reason:                  reason,
        request:                 DataTypes.create_request(request),
        community:               Maybe(community).map { |c| DataTypes.create_community(c) }.or_else(nil),
        paths:                   DataTypes.create_paths(paths),
        configs:                 DataTypes.create_configs(configs),
        protocol:                new_protocol,
        protocol_needs_redirect: protocol_needs_redirect,
      )

      block.call(target) if target
    end
  end

  # private

  # The main "router function"
  #
  # Returns a hash, which contains either a url or named route
  #
  # Example, return hash with url:
  #
  # { url: "https://marketplace.sharetribe.com/listings", status :found }
  #
  # Example, return hash with named route:
  #
  # { route_name: :new_community, status: :moved_permanently, protocol: "http"}
  #
  # rubocop:disable ParameterLists
  def redirect_target(reason:, request:, community:, paths:, configs:, protocol:, protocol_needs_redirect:)
    target =
      case reason
      when :new_marketplace
        # Community not found, because there are no communities
        # -> Redirect to new community page
        paths[:new_community].merge(status: :found, protocol: protocol)
      when :not_found
        # Community not found
        # -> Redirect to not found
        Maybe(paths[:community_not_found])[:url].map { |u|
          URLUtils.build_url(u, {utm_source: request[:host], utm_medium: "redirect", utm_campaign: "na-auto-redirect"})
        }.map { |u|
          {url: u, status: :found, protocol: protocol}
        }.or_else {
          paths[:community_not_found].merge(status: :found, protocol: protocol)
        }
      when :deleted
        # Community deleted
        # -> Redirect to not found
        Maybe(paths[:community_not_found])[:url].map { |u|
          URLUtils.build_url(u, {utm_source: request[:host], utm_medium: "redirect", utm_campaign: "dl-auto-redirect"})
        }.map { |u|
          {url: u, status: :moved_permanently, protocol: protocol}
        }.or_else {
          paths[:community_not_found].merge(status: :moved_permanently, protocol: protocol)
        }
      when :closed
        # Community closed
        # -> Redirect to not found
        Maybe(paths[:community_not_found])[:url].map { |u|
          URLUtils.build_url(u, {utm_source: request[:host], utm_medium: "redirect", utm_campaign: "qc-auto-redirect"})
        }.map { |u|
          {url: u, status: :moved_permanently, protocol: protocol}
        }.or_else {
          paths[:community_not_found].merge(status: :moved_permanently, protocol: protocol)
        }
      when :domain
        # Community has domain ready, should use it
        # -> Redirect to community domain
        {url: "#{protocol}://#{community[:domain]}#{request[:port_string]}#{request[:fullpath]}", status: :moved_permanently}
      when :no_domain
        # Community has a domain, but it's not in use.
        # -> Redirect to subdomain (ident)
        {url: "#{protocol}://#{community[:ident]}.#{configs[:app_domain]}#{request[:port_string]}#{request[:fullpath]}", status: :moved_permanently}
      when :www_ident
        # Accessed community with ident, including www
        # -> Redirect to ident without www
        {url: "#{protocol}://#{community[:ident]}.#{configs[:app_domain]}#{request[:port_string]}#{request[:fullpath]}", status: :moved_permanently}
      when :https
        # Needs protocol redirect (to https)
        # -> Redirect to https
        {url: "#{protocol}://#{request[:host]}#{request[:port_string]}#{request[:fullpath]}", status: :moved_permanently}
      else
        raise ArgumentError.new("Unknown redirect reason: '#{reason}'")
      end

    # If protocol redirect is needed, the status is always :moved_permanently
    target_with_status = target.merge(status: protocol_needs_redirect ? :moved_permanently : target[:status])

    HashUtils.compact(DataTypes::Target.call(target_with_status.merge(reason: reason)))
  end
  # rubocop:enable ParameterLists

  def redirect_reason(request:, community:, configs:, other:, protocol_needs_redirect:)
    if other[:community_search_status] == :not_found && other[:no_communities]
      :new_marketplace
    elsif other[:community_search_status] == :not_found && !other[:no_communities]
      :not_found
    elsif community && community[:deleted]
      :deleted
    elsif community && community[:closed]
      :closed
    elsif community && community[:domain].present? && community[:use_domain] && request[:host] != community[:domain]
      :domain
    elsif community && community[:domain].present? && !community[:use_domain] && request[:host] == community[:domain]
      :no_domain
    elsif community && request[:host] == "www.#{community[:ident]}.#{configs[:app_domain]}"
      :www_ident
    elsif protocol_needs_redirect
      :https
    else
      nil
    end
  end

  def protocol(request:, community:, configs:)
    if should_use_https?(request: request, community: community, configs: configs)
      "https"
    else
      request[:protocol] == "http://" ? "http" : "https"
    end
  end

  def should_use_https?(request:, configs:, community:)
    from_proxy = (request[:headers]["HTTP_VIA"] && request[:headers]["HTTP_VIA"].include?("sharetribe_proxy"))
    robots = request[:fullpath] == "/robots.txt"

    configs[:always_use_ssl] && !from_proxy && !robots
  end

end
