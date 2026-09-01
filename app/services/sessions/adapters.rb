module Sessions
  # Registry of the agent transcript formats SeshQL knows how to read.
  #
  # Adapters are resolved lazily rather than held in a frozen constant so that
  # a reload in development hands back the current class objects.
  module Adapters
    def self.all = [ ClaudeCode, Codex ]

    # Adapters whose session directory actually exists on this machine.
    def self.enabled = all.select(&:available?)

    # The adapter that owns a path, or nil when the path is not under any
    # known agent's session directory.
    def self.for_path(path)
      expanded = File.expand_path(path)
      all.find { |adapter| adapter.owns?(expanded) }
    end

    def self.for_source(source)
      all.find { |adapter| adapter.source == source.to_s }
    end

    # Every transcript file on disk, across every agent.
    def self.discover = enabled.flat_map(&:discover)
  end
end
