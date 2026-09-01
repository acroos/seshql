module Sessions
  # The normalized output of an adapter: rows ready to be upserted, plus the
  # session-level attributes the adapter learned from the file.
  #
  # Every adapter produces one of these regardless of what the agent's own
  # transcript format looks like, so `Sessions::Ingester` never has to know
  # which agent it is ingesting.
  class ParsedTranscript
    TABLES = %i[
      messages
      user_prompts
      tool_results
      assistant_messages
      content_blocks
      system_events
      attachments
      pr_links
      file_history_snapshots
    ].freeze

    attr_reader :session_attrs, *TABLES

    def initialize
      @session_attrs = {}
      TABLES.each { |table| instance_variable_set(:"@#{table}", []) }
    end

    # Later values win, so a transcript that revises a session-level fact
    # (a renamed title, a new permission mode) ends up with the latest one.
    def set_session(attrs)
      @session_attrs.merge!(attrs.compact)
    end

    def record_count
      TABLES.sum { |table| public_send(table).size }
    end
  end
end
