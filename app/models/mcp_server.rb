class McpServer < ApplicationRecord
  has_many :skills, dependent: :destroy

  STATUSES = %w[online offline degraded unknown error].freeze

  validates :name, presence: true, uniqueness: true
  validates :repository_url, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :online, -> { where(status: "online") }
  scope :offline, -> { where(status: "offline") }
  scope :with_issues, -> { where(status: %w[degraded error]) }

  def online?
    status == "online"
  end

  def offline?
    status == "offline"
  end

  def healthy?
    status == "online" && last_error.blank?
  end

  def check_health!
    return unless port.present?

    uri = URI("http://localhost:#{port}/up")
    response = Net::HTTP.get_response(uri)

    if response.code == "200"
      update!(status: "online", last_health_check_at: Time.current, last_error: nil)
    else
      update!(status: "degraded", last_health_check_at: Time.current, last_error: "HTTP #{response.code}")
    end
  rescue StandardError => e
    update!(status: "offline", last_health_check_at: Time.current, last_error: e.message)
  end

  def status_color
    case status
    when "online" then "green"
    when "offline" then "red"
    when "degraded" then "yellow"
    when "error" then "red"
    else "gray"
    end
  end

  def skill_count
    skills.count
  end

  def active_skill_count
    skills.where(status: "available").count
  end
end
