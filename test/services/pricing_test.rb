require "test_helper"

class PricingTest < ActiveSupport::TestCase
  test "prices a Claude turn with split cache-write tiers" do
    usage = {
      "input_tokens" => 1_000_000,
      "output_tokens" => 1_000_000,
      "cache_read_input_tokens" => 1_000_000,
      "cache_creation_input_tokens" => 2_000_000,
      "cache_creation" => {
        "ephemeral_5m_input_tokens" => 1_000_000,
        "ephemeral_1h_input_tokens" => 1_000_000
      }
    }

    # opus-5 is $5/$25 per million: 5 fresh + 6.25 write-5m + 10 write-1h
    # + 0.5 read + 25 output.
    assert_in_delta 46.75, Pricing.cost_for_usage("claude-opus-5", usage, source: "claude_code"), 1e-9
  end

  test "prices a Codex turn, billing cache writes at nothing" do
    usage = {
      "input_tokens" => 1_000_000,
      "output_tokens" => 1_000_000,
      "cache_read_input_tokens" => 1_000_000,
      "cache_creation_input_tokens" => 5_000_000
    }

    # gpt-5.3-codex is $1.75 input / $0.175 cached / $14 output, and OpenAI
    # does not charge for writing to the prompt cache.
    assert_in_delta 15.925, Pricing.cost_for_usage("gpt-5.3-codex", usage, source: "codex"), 1e-9
  end

  test "infers the provider from the model when no source is given" do
    assert_equal Pricing::Anthropic, Pricing.provider_for("claude-sonnet-5", nil)
    assert_equal Pricing::Anthropic, Pricing.provider_for("anthropic.claude-haiku-4-5-20251001", nil)
    assert_equal Pricing::Openai, Pricing.provider_for("gpt-5.3-codex", nil)
    assert_equal Pricing::Openai, Pricing.provider_for("o4-mini", nil)
    assert_nil Pricing.provider_for("some-local-model", nil)
  end

  test "an explicit source wins over the model name" do
    assert_equal Pricing::Openai, Pricing.provider_for("claude-opus-5", "codex")
  end

  test "an unknown model is unpriced rather than free" do
    usage = { "input_tokens" => 100, "output_tokens" => 100 }

    assert_nil Pricing.cost_for_usage("gpt-9-imaginary", usage, source: "codex")
    assert_nil Pricing.cost_for_usage("claude-imaginary-9", usage, source: "claude_code")
  end

  test "each provider reports its own cost components" do
    usage = { "input_tokens" => 10, "output_tokens" => 10,
              "cache_read_input_tokens" => 10, "cache_creation_input_tokens" => 10 }

    assert_equal [ "Fresh input", "Cache write (5m)", "Cache write (1h)", "Cache read", "Output" ],
                 Pricing.components_for_usage("claude-opus-5", usage, source: "claude_code").map(&:label)
    assert_equal [ "Fresh input", "Cache write", "Cache read", "Output" ],
                 Pricing.components_for_usage("gpt-5.3-codex", usage, source: "codex").map(&:label)
  end

  test "only Anthropic bills web search per request" do
    usage = { "server_tool_use" => { "web_search_requests" => 3 } }

    assert_equal 3, Pricing.web_search_requests(usage, source: "claude_code")
    assert_equal 0, Pricing.web_search_requests(usage, source: "codex")
    assert_equal 0.0, Pricing.web_search_usd(source: "codex")
  end

  test "normalizes pinned model snapshots to their base rate" do
    assert_equal Pricing::Anthropic::RATES["claude-haiku-4-5"],
                 Pricing::Anthropic.rates_for("claude-haiku-4-5@20251001")
    assert_equal Pricing::Openai::RATES["gpt-5.3-codex"],
                 Pricing::Openai.rates_for("gpt-5.3-codex-2026-04-01")
  end
end
