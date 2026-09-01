module Pricing
  # Claude API token pricing.
  #
  # Rates are USD per million tokens, taken from
  # https://platform.claude.com/docs/en/about-claude/pricing (fetched 2026-08-30).
  # Cache writes and cache reads are multipliers on the model's base input rate,
  # so only the base input and output rates need a table entry per model.
  module Anthropic
    RATES = {
      "claude-fable-5"    => { input: 10.0, output: 50.0 },
      "claude-mythos-5"   => { input: 10.0, output: 50.0 },
      "claude-opus-5"     => { input: 5.0,  output: 25.0 },
      "claude-opus-4-8"   => { input: 5.0,  output: 25.0 },
      "claude-opus-4-7"   => { input: 5.0,  output: 25.0 },
      "claude-opus-4-6"   => { input: 5.0,  output: 25.0 },
      "claude-opus-4-5"   => { input: 5.0,  output: 25.0 },
      "claude-opus-4-1"   => { input: 15.0, output: 75.0 },
      "claude-opus-4"     => { input: 15.0, output: 75.0 },
      "claude-sonnet-5"   => { input: 2.0,  output: 10.0 },
      "claude-sonnet-4-6" => { input: 3.0,  output: 15.0 },
      "claude-sonnet-4-5" => { input: 3.0,  output: 15.0 },
      "claude-sonnet-4"   => { input: 3.0,  output: 15.0 },
      "claude-haiku-4-5"  => { input: 1.0,  output: 5.0 },
      "claude-haiku-3-5"  => { input: 0.8,  output: 4.0 }
    }.freeze

    # Fast mode (research preview) reprices Opus 5 / 4.8 at the Fable 5 tier.
    FAST_RATES = { input: 10.0, output: 50.0 }.freeze
    FAST_MODE_MODELS = %w[claude-opus-5 claude-opus-4-8].freeze

    CACHE_WRITE_5M_MULTIPLIER = 1.25
    CACHE_WRITE_1H_MULTIPLIER = 2.0
    CACHE_READ_MULTIPLIER     = 0.1

    # inference_geo: "us" pins inference to the United States at a premium.
    US_INFERENCE_MULTIPLIER = 1.1

    # Server-side web search is $10 per 1,000 searches, on top of token cost.
    WEB_SEARCH_USD = 0.01

    # The priced categories a turn's tokens fall into, cheapest-explaining
    # first. Labels are what the UI shows.
    COMPONENTS = {
      fresh_input:    "Fresh input",
      cache_write_5m: "Cache write (5m)",
      cache_write_1h: "Cache write (1h)",
      cache_read:     "Cache read",
      output:         "Output"
    }.freeze

    class << self
      def components_for_usage(model, usage)
        rates = rates_for(model, speed: usage["speed"])
        geo = usage["inference_geo"].to_s == "us" ? US_INFERENCE_MULTIPLIER : 1.0

        priced(usage, rates).map do |key, (tokens, rate)|
          Component.new(
            key: key,
            label: COMPONENTS.fetch(key),
            tokens: tokens,
            cost_usd: rate && (tokens * rate / 1_000_000.0 * geo)
          )
        end
      end

      def web_search_requests(usage)
        usage.dig("server_tool_use", "web_search_requests").to_i
      end

      def surcharges(usage) = web_search_requests(usage) * WEB_SEARCH_USD

      def web_search_usd = WEB_SEARCH_USD

      def rates_for(model, speed: nil)
        id = normalize(model)
        return nil unless RATES.key?(id)
        return FAST_RATES if speed.to_s == "fast" && FAST_MODE_MODELS.include?(id)
        RATES[id]
      end

      # Strips the Bedrock prefix and any pinned-snapshot date suffix so
      # "anthropic.claude-haiku-4-5-20251001" and "claude-haiku-4-5@20251001"
      # both resolve to "claude-haiku-4-5".
      def normalize(model)
        model.to_s.sub(/\Aanthropic\./, "").sub(/[@-]\d{8}\z/, "")
      end

      private

      def priced(usage, rates)
        cache_creation = usage["cache_creation"] || {}
        cache_1h = cache_creation["ephemeral_1h_input_tokens"].to_i
        # Older transcripts record only the total, with no 5m/1h split. Bill
        # the remainder at the 5-minute rate, which is what Claude Code writes
        # by default.
        cache_5m = (cache_creation["ephemeral_5m_input_tokens"] ||
                    (usage["cache_creation_input_tokens"].to_i - cache_1h)).to_i

        {
          fresh_input:    [ usage["input_tokens"].to_i,            rates && rates[:input] ],
          cache_write_5m: [ cache_5m,                              rates && rates[:input] * CACHE_WRITE_5M_MULTIPLIER ],
          cache_write_1h: [ cache_1h,                              rates && rates[:input] * CACHE_WRITE_1H_MULTIPLIER ],
          cache_read:     [ usage["cache_read_input_tokens"].to_i, rates && rates[:input] * CACHE_READ_MULTIPLIER ],
          output:         [ usage["output_tokens"].to_i,           rates && rates[:output] ]
        }
      end
    end
  end
end
