# Turns raw token usage into a dollar figure.
#
# Each agent bills differently enough that the arithmetic cannot be shared:
# Anthropic charges separately for 5-minute and 1-hour cache writes, OpenAI
# does not bill cache writes at all and discounts cached reads at a per-model
# ratio. So `Pricing` is only a facade, and the per-provider modules under it
# own the rate tables and the component breakdown.
module Pricing
  # tokens/cost for one priced category. cost_usd is nil when the model has no
  # known rate, so callers can tell "free" apart from "unknown".
  Component = Struct.new(:key, :label, :tokens, :cost_usd, keyword_init: true)

  PROVIDERS = {
    "claude_code" => "Anthropic",
    "codex" => "Openai"
  }.freeze

  class << self
    # Splits one assistant turn's `usage` hash into priced components, in the
    # order the UI should display them.
    def components_for_usage(model, usage, source: nil)
      provider = provider_for(model, source)
      return [] unless provider

      provider.components_for_usage(model, usage.presence || {})
    end

    # Cost in USD for one assistant turn. Returns nil for models we have no
    # rate for, including an agent's synthetic error messages.
    def cost_for_usage(model, usage, source: nil)
      provider = provider_for(model, source)
      return nil unless provider

      components = provider.components_for_usage(model, usage.presence || {})
      return nil if components.empty? || components.any? { |c| c.cost_usd.nil? }

      components.sum(&:cost_usd) + provider.surcharges(usage.presence || {})
    end

    def web_search_requests(usage, source: nil, model: nil)
      provider = provider_for(model, source)
      return 0 unless provider

      provider.web_search_requests(usage.presence || {})
    end

    # Per-request price of a server-side web search, for agents that bill it
    # separately from tokens.
    def web_search_usd(source: nil, model: nil)
      provider_for(model, source)&.web_search_usd || 0.0
    end

    # An explicit source always wins. Falling back to the model name keeps
    # callers that only have a stored row (backfills, the cost breakdown)
    # from having to join back to the session.
    def provider_for(model, source)
      name = PROVIDERS[source.to_s] || infer_provider(model)
      const_get(name) if name
    end

    private

    def infer_provider(model)
      case model.to_s
      when /\Aanthropic\./, /\Aclaude/ then "Anthropic"
      when /\Agpt-/, /\Ao\d/, /codex/  then "Openai"
      end
    end
  end
end
