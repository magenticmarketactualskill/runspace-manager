class Skill < ApplicationRecord
  belongs_to :mcp_server

  STATUSES = %w[available unavailable deprecated error].freeze

  validates :name, presence: true
  validates :name, uniqueness: { scope: :mcp_server_id }
  validates :status, inclusion: { in: STATUSES }

  scope :available, -> { where(status: "available") }
  scope :unavailable, -> { where(status: "unavailable") }
  scope :with_errors, -> { where(status: "error") }

  def available?
    status == "available"
  end

  def error_rate
    return 0 if invocation_count.zero?
    (error_count.to_f / invocation_count * 100).round(2)
  end

  def record_invocation!(latency_ms:, success:, error_message: nil)
    new_count = invocation_count + 1
    new_error_count = success ? error_count : error_count + 1

    new_avg = if average_latency_ms.nil?
                latency_ms
              else
                ((average_latency_ms * invocation_count) + latency_ms) / new_count
              end

    attrs = {
      invocation_count: new_count,
      error_count: new_error_count,
      average_latency_ms: new_avg.round(2),
      last_invoked_at: Time.current
    }
    attrs[:last_error] = error_message unless success

    update!(attrs)
  end

  def status_color
    case status
    when "available" then "green"
    when "unavailable" then "gray"
    when "deprecated" then "yellow"
    when "error" then "red"
    else "gray"
    end
  end
end
