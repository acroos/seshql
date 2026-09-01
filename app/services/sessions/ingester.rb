module Sessions
  # Reads one transcript file and upserts it into the schema.
  #
  # Everything agent-specific lives behind `Sessions::Adapters`; this class
  # only decides which adapter owns a file, whether that file has changed since
  # it was last read, and how the normalized rows get written.
  class Ingester
    Result = Struct.new(:status, :lines_processed, :error, keyword_init: true)

    # Which column makes a row unique, so a re-read updates rather than
    # duplicates. Keyed by the `ParsedTranscript` collection it applies to.
    UPSERT_KEYS = {
      messages: [ Message, :uuid ],
      user_prompts: [ UserPrompt, :message_uuid ],
      tool_results: [ ToolResult, :message_uuid ],
      assistant_messages: [ AssistantMessage, :message_uuid ],
      content_blocks: [ ContentBlock, "uniq_content_blocks_on_assistant_position" ],
      system_events: [ SystemEvent, :message_uuid ],
      attachments: [ Attachment, :message_uuid ],
      pr_links: [ PrLink, "uniq_pr_links_on_session_repo_number" ],
      file_history_snapshots: [ FileHistorySnapshot, "uniq_file_history_on_session_source" ]
    }.freeze

    # The unique key each collection dedupes on before it reaches Postgres,
    # which rejects a statement that touches the same row twice.
    DEDUPE_KEYS = {
      messages: ->(row) { row[:uuid] },
      content_blocks: ->(row) { [ row[:assistant_message_uuid], row[:position] ] },
      pr_links: ->(row) { [ row[:session_id], row[:pr_repository], row[:pr_number] ] },
      file_history_snapshots: ->(row) { [ row[:session_id], row[:source_message_id] ] }
    }.freeze
    DEFAULT_DEDUPE_KEY = ->(row) { row[:message_uuid] }

    NUL = "\u0000".freeze

    def self.call(file_path)
      new(file_path).call
    end

    def initialize(file_path)
      @file_path = File.expand_path(file_path)
    end

    def call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = run
      record_run(result, started)
      result
    rescue => e
      record_run(Result.new(status: :failed, lines_processed: 0, error: e), started)
      raise
    end

    private

    attr_reader :file_path

    def run
      return Result.new(status: :missing, lines_processed: 0) unless File.exist?(file_path)

      adapter = Adapters.for_path(file_path)
      session_id = adapter&.session_id_for(file_path)
      return Result.new(status: :unsupported, lines_processed: 0) if session_id.blank?

      stat = File.stat(file_path)
      tracked = SessionFile.find_or_initialize_by(file_path: file_path)
      return Result.new(status: :skipped, lines_processed: 0) if up_to_date?(tracked, stat)

      offset = read_offset(adapter, tracked, stat)
      records = read_records(adapter, offset)

      count = persist(adapter, session_id, records, tracked, stat)
      Result.new(status: :succeeded, lines_processed: count)
    end

    def up_to_date?(tracked, stat)
      tracked.persisted? &&
        tracked.file_mtime.present? &&
        tracked.file_size == stat.size &&
        tracked.file_mtime.to_i == stat.mtime.to_i
    end

    # A file is resumed from where the last read stopped, unless the adapter
    # says its format cannot be read in pieces, or the file has been rewritten
    # shorter than the offset we hold.
    def read_offset(adapter, tracked, stat)
      return 0 unless tracked.persisted? && adapter.resumable?(file_path)

      offset = tracked.last_byte_offset.to_i
      offset > stat.size ? 0 : offset
    end

    def read_records(adapter, offset)
      records = []
      adapter.each_record(file_path, offset: offset) { |record| records << record }
      records
    end

    def persist(adapter, session_id, records, tracked, stat)
      session = Session.find_or_initialize_by(session_id: session_id)
      session.source = adapter.source
      newly_created = session.new_record?

      # A resumed read that found nothing new still needs its watermark moved
      # forward so the file stops being re-enqueued.
      if records.empty? && !newly_created
        touch_watermark(tracked, session_id, adapter, stat)
        return 0
      end

      parsed = adapter.parse(records, session_id: session_id, file_path: file_path)
      new_pr_link_keys = []

      ActiveRecord::Base.transaction do
        apply_session_attributes(session, parsed.session_attrs)
        session.save! if session.new_record? || session.changed?

        new_pr_link_keys = write_rows(parsed)
        self.class.recompute_aggregates(session_id)

        session.update!(created_at: earliest_message_timestamp(session_id) || session.created_at || Time.current)
        touch_watermark(tracked, session_id, adapter, stat)
      end

      enqueue_enrichment(session, newly_created, new_pr_link_keys)
      records.size
    end

    # An adapter only reports what the file told it, so a nil never clears a
    # value an earlier file or an earlier read already established.
    def apply_session_attributes(session, attrs)
      attrs.each do |column, value|
        next if value.nil?
        session[column] = value
      end
    end

    def touch_watermark(tracked, session_id, adapter, stat)
      tracked.update!(
        session_id: session_id,
        source: adapter.source,
        file_mtime: stat.mtime,
        file_size: stat.size,
        last_byte_offset: stat.size,
        last_ingested_at: Time.current
      )
    end

    def write_rows(parsed)
      ParsedTranscript::TABLES.each do |table|
        rows = dedupe(parsed.public_send(table), table)
        next if rows.empty?

        model, unique_by = UPSERT_KEYS.fetch(table)
        model.upsert_all(scrub(square_off(rows)), unique_by: unique_by)
      end

      parsed.pr_links.map { |link| link.slice(:pr_repository, :pr_number) }
    end

    # `upsert_all` rejects a batch whose rows do not all carry the same keys,
    # and an adapter legitimately omits keys that do not apply to a row (a text
    # content block has no tool name). Missing keys become explicit nils.
    def square_off(rows)
      template = rows.flat_map(&:keys).uniq.index_with(nil)
      rows.map { |row| template.merge(row) }
    end

    # Postgres accepts no NUL character in either `text` or `jsonb`, and a
    # transcript picks one up whenever a tool touched binary content. Dropping
    # it costs nothing queryable and keeps one bad byte from failing the whole
    # file.
    def scrub(rows)
      rows.map { |row| row.transform_values { |value| scrub_value(value) } }
    end

    def scrub_value(value)
      case value
      when String then value.include?(NUL) ? value.delete(NUL) : value
      when Hash then value.to_h { |key, nested| [ scrub_value(key), scrub_value(nested) ] }
      when Array then value.map { |nested| scrub_value(nested) }
      else value
      end
    end

    def dedupe(rows, table)
      key = DEDUPE_KEYS.fetch(table, DEFAULT_DEDUPE_KEY)
      seen = {}
      rows.each { |row| seen[key.call(row)] = row }
      seen.values
    end

    def enqueue_enrichment(session, newly_created, new_pr_link_keys)
      ResolveRepoJob.perform_later(session.session_id) if newly_created && session.repo_id.nil?
      return if new_pr_link_keys.empty?

      ids = PrLink.where(
        session_id: session.session_id,
        pr_repository: new_pr_link_keys.map { |k| k[:pr_repository] }.uniq,
        pr_number: new_pr_link_keys.map { |k| k[:pr_number] }.uniq
      ).where(pr_title: nil).pluck(:id)
      ids.each { |id| EnrichPrLinkJob.perform_later(id) }
    end

    def earliest_message_timestamp(session_id)
      Message.where(session_id: session_id).minimum(:timestamp)
    end

    def record_run(result, started)
      return if result.status == :skipped # avoid noise

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      IngestionRun.create!(
        file_path: file_path,
        status: result.status.to_s,
        error_class: result.error&.class&.name,
        error_message: result.error&.message,
        lines_processed: result.lines_processed,
        duration_ms: duration_ms,
        run_at: Time.current
      )
    rescue => e
      Rails.logger.warn("[ingester] failed to record run: #{e.message}")
    end

    RECOMPUTE_AGGREGATES_SQL = <<~SQL.freeze
      UPDATE sessions SET
        branch                      = sub.branch,
        first_prompt                = sub.first_prompt,
        ended_at                    = sub.ended_at,
        total_input_tokens          = sub.total_input_tokens,
        total_output_tokens         = sub.total_output_tokens,
        total_cache_creation_tokens = sub.total_cache_creation_tokens,
        total_cache_read_tokens     = sub.total_cache_read_tokens,
        total_cost_usd              = sub.total_cost_usd,
        user_message_count          = sub.user_message_count,
        assistant_message_count     = sub.assistant_message_count,
        active_duration_ms          = sub.active_duration_ms,
        pr_link_count               = sub.pr_link_count,
        files_edited_count          = sub.files_edited_count,
        git_commit_count            = sub.git_commit_count,
        tools_used                  = sub.tools_used
      FROM (
        SELECT
          (SELECT git_branch FROM messages
             WHERE session_id = :session_id AND git_branch IS NOT NULL
             ORDER BY timestamp ASC LIMIT 1) AS branch,
          (SELECT up.content_text FROM user_prompts up
             JOIN messages m ON m.uuid = up.message_uuid
             WHERE m.session_id = :session_id AND up.is_meta = false
             ORDER BY m.timestamp ASC LIMIT 1) AS first_prompt,
          (SELECT MAX(timestamp) FROM messages WHERE session_id = :session_id) AS ended_at,
          COALESCE((SELECT SUM(am.input_tokens + am.cache_creation_input_tokens + am.cache_read_input_tokens)
             FROM assistant_messages am
             JOIN messages m ON m.uuid = am.message_uuid
             WHERE m.session_id = :session_id), 0) AS total_input_tokens,
          COALESCE((SELECT SUM(am.output_tokens)
             FROM assistant_messages am
             JOIN messages m ON m.uuid = am.message_uuid
             WHERE m.session_id = :session_id), 0) AS total_output_tokens,
          COALESCE((SELECT SUM(am.cache_creation_input_tokens)
             FROM assistant_messages am
             JOIN messages m ON m.uuid = am.message_uuid
             WHERE m.session_id = :session_id), 0) AS total_cache_creation_tokens,
          COALESCE((SELECT SUM(am.cache_read_input_tokens)
             FROM assistant_messages am
             JOIN messages m ON m.uuid = am.message_uuid
             WHERE m.session_id = :session_id), 0) AS total_cache_read_tokens,
          (SELECT SUM(am.cost_usd)
             FROM assistant_messages am
             JOIN messages m ON m.uuid = am.message_uuid
             WHERE m.session_id = :session_id) AS total_cost_usd,
          (SELECT COUNT(*)
             FROM user_prompts up
             JOIN messages m ON m.uuid = up.message_uuid
             WHERE m.session_id = :session_id
               AND m.is_sidechain = false
               AND up.is_meta = false) AS user_message_count,
          (SELECT COUNT(*)
             FROM assistant_messages am
             JOIN messages m ON m.uuid = am.message_uuid
             WHERE m.session_id = :session_id) AS assistant_message_count,
          COALESCE((SELECT SUM(se.duration_ms)
             FROM system_events se
             JOIN messages m ON m.uuid = se.message_uuid
             WHERE m.session_id = :session_id
               AND se.subtype = 'turn_duration'), 0) AS active_duration_ms,
          (SELECT COUNT(*) FROM pr_links WHERE session_id = :session_id) AS pr_link_count,
          (SELECT COUNT(DISTINCT COALESCE(
                    cb.tool_input ->> 'file_path',
                    cb.tool_input ->> 'path',
                    cb.tool_input ->> 'file'))
             FROM content_blocks cb
             JOIN assistant_messages am ON am.message_uuid = cb.assistant_message_uuid
             JOIN messages m ON m.uuid = am.message_uuid
             WHERE m.session_id = :session_id
               AND cb.block_type = 'tool_use'
               AND cb.tool_kind = 'edit'
               AND COALESCE(
                     cb.tool_input ->> 'file_path',
                     cb.tool_input ->> 'path',
                     cb.tool_input ->> 'file') IS NOT NULL) AS files_edited_count,
          (SELECT COUNT(*)
             FROM content_blocks cb
             JOIN assistant_messages am ON am.message_uuid = cb.assistant_message_uuid
             JOIN messages m ON m.uuid = am.message_uuid
             WHERE m.session_id = :session_id
               AND cb.bash_command ~ '(^|[;&|]\\s*)git\\s+commit') AS git_commit_count,
          COALESCE((SELECT array_agg(DISTINCT cb.tool_name)
             FROM content_blocks cb
             JOIN assistant_messages am ON am.message_uuid = cb.assistant_message_uuid
             JOIN messages m ON m.uuid = am.message_uuid
             WHERE m.session_id = :session_id
               AND cb.block_type = 'tool_use'
               AND cb.tool_name IS NOT NULL), ARRAY[]::text[]) AS tools_used
      ) sub
      WHERE sessions.session_id = :session_id;
    SQL

    def self.recompute_aggregates(session_id)
      sql = ActiveRecord::Base.sanitize_sql_array(
        [ RECOMPUTE_AGGREGATES_SQL, { session_id: session_id } ]
      )
      Session.connection.exec_update(sql, "RecomputeSessionAggregates")
    end
  end
end
