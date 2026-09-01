module Pricing
  # OpenAI token pricing, used for Codex sessions.
  #
  # Rates are USD per million tokens from
  # https://developers.openai.com/api/docs/pricing (fetched 2026-08-31).
  #
  # Two differences from Anthropic's model matter here:
  #
  #   * Cache writes are not billed, so `cache_creation_input_tokens` shows up
  #     in the breakdown at zero cost rather than being hidden.
  #   * The cached-read discount is a per-model rate, not a fixed multiple of
  #     the input rate (the GPT-5 family discounts to 10%, the o-series to 25%),
  #     so each entry carries its own `cached` rate.
  #
  # Codex can run a model in "fast mode" at a higher rate. Nothing in the
  # rollout file records which mode a turn used, so standard rates are assumed
  # and fast-mode sessions will read low.
  module Openai
    RATES = {
      "gpt-5.3-codex" => { input: 1.75, cached: 0.175, output: 14.0 },
      "gpt-5.6-sol"   => { input: 4.0,  cached: 0.40,  output: 20.0 },
      "gpt-5.6-terra" => { input: 2.0,  cached: 0.20,  output: 12.0 },
      "gpt-5.6-luna"  => { input: 0.20, cached: 0.02,  output: 1.20 },
      "gpt-5.5"       => { input: 5.0,  cached: 0.50,  output: 30.0 },
      "gpt-5.4"       => { input: 2.50, cached: 0.25,  output: 15.0 },
      "gpt-5.4-mini"  => { input: 0.75, cached: 0.075, output: 4.50 },
      "gpt-5.4-nano"  => { input: 0.20, cached: 0.02,  output: 1.25 },
      "gpt-5.2"       => { input: 1.75, cached: 0.175, output: 14.0 },
      "gpt-5.2-pro"   => { input: 21.0, cached: 21.0,  output: 168.0 },
      "gpt-5.1"       => { input: 1.25, cached: 0.125, output: 10.0 },
      "gpt-5"         => { input: 1.25, cached: 0.125, output: 10.0 },
      "gpt-5-mini"    => { input: 0.25, cached: 0.025, output: 2.0 },
      "gpt-5-nano"    => { input: 0.05, cached: 0.005, output: 0.40 },
      "gpt-5-pro"     => { input: 15.0, cached: 15.0,  output: 120.0 },
      "o3"            => { input: 2.0,  cached: 0.50,  output: 8.0 },
      "o4-mini"       => { input: 1.10, cached: 0.275, output: 4.40 }
    }.freeze

    COMPONENTS = {
      fresh_input: "Fresh input",
      cache_write: "Cache write",
      cache_read:  "Cache read",
      output:      "Output"
    }.freeze

    class << self
      def components_for_usage(model, usage)
        rates = rates_for(model)

        priced(usage, rates).map do |key, (tokens, rate)|
          Component.new(
            key: key,
            label: COMPONENTS.fetch(key),
            tokens: tokens,
            cost_usd: rate && tokens * rate / 1_000_000.0
          )
        end
      end

      # Codex bills web search through the model's own tokens rather than as a
      # separate per-request charge.
      def web_search_requests(_usage) = 0

      def surcharges(_usage) = 0.0

      def web_search_usd = 0.0

      def rates_for(model) = RATES[normalize(model)]

      # Strips a pinned-snapshot date suffix so "gpt-5.3-codex-2026-04-01"
      # resolves to "gpt-5.3-codex".
      def normalize(model)
        model.to_s.sub(/-\d{4}-\d{2}-\d{2}\z/, "").sub(/-\d{8}\z/, "")
      end

      private

      def priced(usage, rates)
        {
          fresh_input: [ usage["input_tokens"].to_i,            rates && rates[:input] ],
          # Prompt-cache writes are not billed separately by OpenAI.
          cache_write: [ usage["cache_creation_input_tokens"].to_i, rates && 0.0 ],
          cache_read:  [ usage["cache_read_input_tokens"].to_i, rates && rates[:cached] ],
          output:      [ usage["output_tokens"].to_i,           rates && rates[:output] ]
        }
      end
    end
  end
end
