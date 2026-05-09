module Sessions
  class PathLookup
    HISTORY_FILE = File.expand_path("~/.claude/history.jsonl").freeze

    def self.build
      new.build
    end

    def self.derive_project_path(file_path, projects_dir)
      relative = file_path.sub("#{projects_dir}/", "")
      relative.split("/").first
    end

    def build
      return {} unless File.exist?(HISTORY_FILE)

      lookup = {}
      File.foreach(HISTORY_FILE) do |line|
        entry = JSON.parse(line)
        real_path = entry["project"]
        next unless real_path

        encoded = real_path.gsub("/", "-").gsub(".", "-")
        lookup[encoded] = real_path
      end
      lookup
    rescue => e
      Rails.logger.warn("Could not read history.jsonl: #{e.message}")
      {}
    end
  end
end
