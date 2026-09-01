module Sessions
  # Rolls a session's assistant turns up into per-category token and dollar
  # totals, so the detail page can show where a session's spend actually went
  # (cache reads usually dwarf everything else by token count but not by cost).
  #
  # The categories themselves come from the agent's pricing model, since
  # Anthropic and OpenAI do not bill the same buckets.
  class CostBreakdown
    Line = Struct.new(:label, :tokens, :cost_usd, :share, keyword_init: true)
    Result = Struct.new(:lines, :total_cost_usd, :unpriced_turns, keyword_init: true)

    def self.for_session(session) = new(session).call

    def initialize(session)
      @session = session
      @source = session.source
    end

    def call
      tokens = Hash.new(0)
      costs = Hash.new(0.0)
      order = []
      web_searches = 0
      unpriced_turns = 0

      @session.assistant_messages.find_each do |message|
        usage = message.usage_hash
        web_searches += Pricing.web_search_requests(usage, source: @source, model: message.model)
        components = Pricing.components_for_usage(message.model, usage, source: @source)

        unpriced_turns += 1 if components.empty? || components.any? { |c| c.cost_usd.nil? }

        components.each do |component|
          order << component.label unless tokens.key?(component.label)
          tokens[component.label] += component.tokens
          costs[component.label] += component.cost_usd if component.cost_usd
        end
      end

      web_cost = web_searches * Pricing.web_search_usd(source: @source)
      total = costs.values.sum + web_cost

      lines = order.filter_map do |label|
        next if tokens[label].zero?
        line(label, tokens[label], costs[label], total)
      end
      lines << line("Web search (#{web_searches})", nil, web_cost, total) if web_searches.positive?

      Result.new(lines: lines, total_cost_usd: total, unpriced_turns: unpriced_turns)
    end

    private

    def line(label, tokens, cost, total)
      Line.new(
        label: label,
        tokens: tokens,
        cost_usd: cost,
        share: total.positive? ? (cost / total * 100) : 0.0
      )
    end
  end
end
