namespace :runspace do
  CONFIG_FILE = Rails.root.join(".runspace/code_structure.ini")

  desc "Clone all MCP servers from .runspace/code_structure.ini"
  task clone_servers: :environment do
    servers = parse_config_section("MCP SERVERS")

    if servers.empty?
      puts "No MCP servers configured in .runspace/code_structure.ini"
      exit
    end

    servers.each do |repo_url|
      clone_repo(repo_url, "mcp_servers")
    end

    puts "\nDone! #{servers.count} MCP server(s) processed."
  end

  desc "Clone all gems from .runspace/code_structure.ini"
  task clone_gems: :environment do
    gems = parse_config_section("GEMS")

    if gems.empty?
      puts "No gems configured in .runspace/code_structure.ini"
      exit
    end

    gems.each do |repo_url|
      clone_repo(repo_url, "gem")
    end

    puts "\nDone! #{gems.count} gem(s) processed."
  end

  desc "Clone all repositories (MCP servers and gems)"
  task clone_all: :environment do
    Rake::Task["runspace:clone_servers"].invoke
    Rake::Task["runspace:clone_gems"].invoke
  end

  desc "Update all MCP servers (git pull)"
  task update_servers: :environment do
    update_repos("mcp_servers")
  end

  desc "Update all gems (git pull)"
  task update_gems: :environment do
    update_repos("gem")
  end

  desc "Update all repositories"
  task update_all: :environment do
    Rake::Task["runspace:update_servers"].invoke
    Rake::Task["runspace:update_gems"].invoke
  end

  desc "Show status of all repositories"
  task status: :environment do
    puts "=== MCP Servers ==="
    show_repo_status("mcp_servers")
    puts "\n=== Gems ==="
    show_repo_status("gem")
  end

  private

  def parse_config_section(section_name)
    unless File.exist?(CONFIG_FILE)
      puts "Error: #{CONFIG_FILE} not found"
      puts "Copy .runspace/code_structure.ini.example to .runspace/code_structure.ini and configure your repositories"
      exit 1
    end

    content = File.read(CONFIG_FILE)
    in_section = false
    entries = []

    content.each_line do |line|
      line = line.strip

      if line.start_with?("[") && line.end_with?("]")
        in_section = (line == "[#{section_name}]")
        next
      end

      next if line.empty? || line.start_with?("#")

      entries << line if in_section && line.start_with?("http")
    end

    entries
  end

  def clone_repo(repo_url, target_dir)
    repo_name = repo_name_from_url(repo_url)
    target_path = Rails.root.join(target_dir, repo_name)

    if Dir.exist?(target_path)
      puts "#{repo_name}: Already exists, skipping (use update task to pull)"
    else
      puts "#{repo_name}: Cloning..."
      system("git", "clone", repo_url, target_path.to_s)
      if $?.success?
        puts "#{repo_name}: Cloned successfully"
      else
        puts "#{repo_name}: Failed to clone"
      end
    end
  end

  def update_repos(target_dir)
    dir_path = Rails.root.join(target_dir)

    unless Dir.exist?(dir_path)
      puts "Directory #{target_dir}/ does not exist"
      return
    end

    repos = Dir.children(dir_path).select do |entry|
      File.directory?(dir_path.join(entry)) && File.directory?(dir_path.join(entry, ".git"))
    end

    if repos.empty?
      puts "No repositories found in #{target_dir}/"
      return
    end

    repos.each do |repo_name|
      repo_path = dir_path.join(repo_name)
      puts "#{repo_name}: Pulling latest changes..."
      Dir.chdir(repo_path) do
        system("git", "pull")
      end
    end

    puts "\nDone! #{repos.count} repository/ies updated."
  end

  def show_repo_status(target_dir)
    dir_path = Rails.root.join(target_dir)

    unless Dir.exist?(dir_path)
      puts "  Directory #{target_dir}/ does not exist"
      return
    end

    repos = Dir.children(dir_path).select do |entry|
      File.directory?(dir_path.join(entry)) && File.directory?(dir_path.join(entry, ".git"))
    end

    if repos.empty?
      puts "  No repositories found"
      return
    end

    repos.each do |repo_name|
      repo_path = dir_path.join(repo_name)
      Dir.chdir(repo_path) do
        branch = `git branch --show-current`.strip
        status = `git status --porcelain`
        status_indicator = status.empty? ? "clean" : "modified"
        puts "  #{repo_name} (#{branch}) - #{status_indicator}"
      end
    end
  end

  def repo_name_from_url(url)
    url.split("/").last.sub(/\.git$/, "")
  end
end
