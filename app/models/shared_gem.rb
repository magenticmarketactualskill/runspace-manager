class SharedGem < ApplicationRecord
  self.table_name = "gems"

  STATUSES = %w[installed outdated missing error unknown].freeze

  validates :name, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :installed, -> { where(status: "installed") }
  scope :outdated, -> { where(status: "outdated") }
  scope :with_issues, -> { where(status: %w[missing error]) }

  def installed?
    status == "installed"
  end

  def outdated?
    status == "outdated"
  end

  def healthy?
    status == "installed" && last_error.blank?
  end

  def check_status!
    return unless local_path.present?

    if File.directory?(local_path)
      gemspec_files = Dir.glob(File.join(local_path, "*.gemspec"))
      if gemspec_files.any?
        update!(status: "installed", last_check_at: Time.current, last_error: nil)
      else
        update!(status: "error", last_check_at: Time.current, last_error: "No gemspec found")
      end
    else
      update!(status: "missing", last_check_at: Time.current, last_error: "Directory not found")
    end
  rescue StandardError => e
    update!(status: "error", last_check_at: Time.current, last_error: e.message)
  end

  def status_color
    case status
    when "installed" then "green"
    when "outdated" then "yellow"
    when "missing" then "red"
    when "error" then "red"
    else "gray"
    end
  end

  def dependency_count
    dependencies.is_a?(Array) ? dependencies.size : 0
  end
end
