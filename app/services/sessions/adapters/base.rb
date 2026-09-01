module Sessions
  module Adapters
    # Contract every agent transcript adapter implements.
    #
    # An adapter answers three separate questions:
    #
    #   * discovery - where do this agent's transcripts live, and which files
    #     on disk belong to it?
    #   * identity  - which session does a given file belong to?
    #   * parsing   - what rows does this file's contents normalize into?
    #
    # Discovery and identity are answered from the path alone, so sweeps and
    # the file watcher never have to open a file to route it.
    class Base
      class << self
        # Value stored in `sessions.source`.
        def source = raise NotImplementedError

        # Human-readable name for logs and the UI.
        def label = raise NotImplementedError

        # Directories this agent writes transcripts to. Missing directories are
        # fine, they just mean the agent isn't installed here.
        def roots = raise NotImplementedError

        def existing_roots = roots.select { |dir| Dir.exist?(dir) }

        def available? = existing_roots.any?

        # Glob patterns, relative to each root, matching transcript files.
        def file_patterns = [ File.join("**", "*.jsonl") ]

        def discover
          existing_roots.flat_map do |root|
            file_patterns.flat_map { |pattern| Dir.glob(File.join(root, pattern)) }
          end.uniq
        end

        def owns?(path)
          # Fall back to the configured roots so a path can still be routed
          # when its directory has been removed since the file was ingested.
          candidates = existing_roots.presence || roots
          candidates.any? { |root| path.start_with?("#{root}#{File::SEPARATOR}") } &&
            transcript?(path)
        end

        def transcript?(path) = File.basename(path).end_with?(".jsonl")

        # The session a file belongs to, derived from its path.
        def session_id_for(_path) = raise NotImplementedError

        # Whether an already-ingested file can be resumed from a byte offset.
        # False forces a full re-read, which upserts make safe.
        def resumable?(_path) = true

        # Yields each decoded JSON object in the file, starting at `offset`.
        # Malformed lines are skipped rather than failing the whole file, since
        # a transcript being appended to can be caught mid-write.
        def each_record(path, offset: 0, &block)
          File.open(path, "rb") do |file|
            file.seek(offset) if offset.positive?
            stream_records(file, path, &block)
          end
        end

        def parse(records, session_id:, file_path:)
          new(session_id: session_id, file_path: file_path).parse(records)
        end

        private

        def stream_records(io, path)
          io.each_line do |line|
            line = line.strip
            next if line.empty?
            begin
              yield JSON.parse(line)
            rescue JSON::ParserError => e
              Rails.logger.warn("[#{source}] skipping malformed line in #{path}: #{e.message}")
            end
          end
        end
      end

      attr_reader :session_id, :file_path

      def initialize(session_id:, file_path:)
        @session_id = session_id
        @file_path = file_path
        @parsed = ParsedTranscript.new
      end

      def parse(_records) = raise NotImplementedError

      private

      attr_reader :parsed

      # Deterministic identifier for a transcript event that has no id of its
      # own. Stable across re-ingests of the same file, which is what makes a
      # full re-read idempotent.
      def synthetic_uuid(*parts)
        Digest::UUID.uuid_v5(Digest::UUID::OID_NAMESPACE,
                             [ self.class.source, session_id, *parts ].join(" "))
      end
    end
  end
end
