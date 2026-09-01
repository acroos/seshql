module Sessions
  # Decodes Claude Code's encoded project directory names
  # (`-Users-me-dev-thing`) back into real filesystem paths, using the record
  # Claude Code keeps in `~/.claude/history.jsonl`.
  #
  # The decoding cannot be done reliably by string substitution alone, because
  # a directory whose own name contains a dash or a dot encodes the same way a
  # path separator does.
  class PathLookup
    class << self
      def history_file
        File.join(Adapters::ClaudeCode.home, "history.jsonl")
      end

      # Memoized for the life of the process, keyed on the history file's
      # mtime and size, so a sweep of hundreds of transcripts reads it once
      # but a newly-created project still shows up.
      def build
        stat = File.stat(history_file)
        key = [ stat.mtime, stat.size ]
        return @lookup if @key == key

        @key = key
        @lookup = read
      rescue Errno::ENOENT
        {}
      end

      def reset!
        @key = nil
        @lookup = nil
      end

      private

      def read
        lookup = {}
        File.foreach(history_file) do |line|
          entry = JSON.parse(line)
          real_path = entry["project"]
          next unless real_path

          lookup[real_path.gsub("/", "-").gsub(".", "-")] = real_path
        end
        lookup
      rescue => e
        Rails.logger.warn("Could not read history.jsonl: #{e.message}")
        {}
      end
    end
  end
end
