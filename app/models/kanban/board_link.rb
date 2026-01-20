# frozen_string_literal: true

module Kanban
  # BoardLink - Manages the RunSpaceManager board in CollaborativeKanban
  # Creates and maintains a single board for tracking Epochs and tasks
  # ALL Epoch cards MUST use this board
  class BoardLink
    BOARD_NAME = "RunSpaceManager"
    BOARD_LEVEL = "team"

    class BoardNotFoundError < StandardError; end
    class BoardCreationError < StandardError; end

    # Column mappings for Epoch states
    COLUMN_MAPPINGS = {
      "pending" => "To Do",
      "running" => "In Progress",
      "paused" => "In Progress",
      "completed" => "Done",
      "stopped" => "Done",
      "failed" => "Done",
      "max_iterations_reached" => "Done"
    }.freeze

    class << self
      def client
        @client ||= Client.new
      end

      def board
        @board ||= find_board
      end

      def board_id
        board&.dig("id")
      end

      def connected?
        client.healthy?
      end

      def reset!
        @board = nil
        @columns = nil
      end

      # Check if the RunSpaceManager board exists in CollaborativeKanban
      def board_exists?
        return false unless connected?

        !!client.find_board_by_name(BOARD_NAME)
      rescue Client::Error
        false
      end

      # Find the RunSpaceManager board (does NOT create it)
      def find_board
        return nil unless connected?

        client.find_board_by_name(BOARD_NAME)
      rescue Client::ConnectionError => e
        Rails.logger.warn "Kanban::BoardLink: Cannot connect to CollaborativeKanban - #{e.message}"
        nil
      end

      # Create the RunSpaceManager board if it doesn't exist
      # Returns the board or raises BoardCreationError
      def create_board!
        return board if board_exists?

        raise BoardCreationError, "Not connected to CollaborativeKanban" unless connected?

        created = client.create_board(
          name: BOARD_NAME,
          level: BOARD_LEVEL,
          description: "Epoch tracking board for RunSpaceManager autonomous loops"
        )

        reset! # Clear cache to pick up new board
        @board = created
        created
      rescue Client::Error => e
        raise BoardCreationError, "Failed to create board: #{e.message}"
      end

      # Ensure the RunSpaceManager board exists, creating it if necessary
      # Returns the board or raises an error
      def ensure_board!
        return board if board

        # Try to create if it doesn't exist
        create_board!

        raise BoardNotFoundError, "RunSpaceManager board not found and could not be created" unless board

        board
      end

      # Check board readiness - returns hash with status info
      def check_board
        {
          connected: connected?,
          board_exists: board_exists?,
          board_id: board_id,
          board_name: BOARD_NAME,
          ready: connected? && board_exists?
        }
      end

      def columns
        return {} unless board_id

        @columns ||= begin
          board_data = client.find_board(board_id)
          (board_data["columns"] || []).index_by { |c| c["name"] }
        end
      end

      def column_for_status(status)
        column_name = COLUMN_MAPPINGS[status.to_s] || "To Do"
        columns[column_name]
      end

      # Epoch card management
      # ALL card operations MUST use the RunSpaceManager board

      def create_epoch_card(epoch)
        ensure_board!
        target_board_id = board_id

        column = column_for_status(epoch.status)
        raise BoardNotFoundError, "Column not found for status: #{epoch.status}" unless column

        client.create_card(
          target_board_id,
          column_id: column["id"],
          title: epoch_card_title(epoch),
          description: epoch_card_description(epoch),
          priority: epoch_priority(epoch),
          card_type: "task",
          external_id: epoch.id,
          metadata: epoch_metadata(epoch)
        )
      rescue BoardNotFoundError, BoardCreationError => e
        Rails.logger.error "Kanban::BoardLink: Board error for epoch #{epoch.id} - #{e.message}"
        nil
      rescue Client::Error => e
        Rails.logger.error "Kanban::BoardLink: Failed to create card for epoch #{epoch.id} - #{e.message}"
        nil
      end

      def update_epoch_card(epoch)
        ensure_board!
        target_board_id = board_id

        card = find_epoch_card(epoch)
        return create_epoch_card(epoch) unless card

        # Update card attributes
        client.update_card(target_board_id, card["id"], {
          title: epoch_card_title(epoch),
          description: epoch_card_description(epoch),
          priority: epoch_priority(epoch),
          metadata: epoch_metadata(epoch).to_json
        })

        # Move to appropriate column if status changed
        target_column = column_for_status(epoch.status)
        if target_column && card["column_id"] != target_column["id"]
          client.move_card(target_board_id, card["id"], column_id: target_column["id"])
        end

        card
      rescue BoardNotFoundError, BoardCreationError => e
        Rails.logger.error "Kanban::BoardLink: Board error for epoch #{epoch.id} - #{e.message}"
        nil
      rescue Client::Error => e
        Rails.logger.error "Kanban::BoardLink: Failed to update card for epoch #{epoch.id} - #{e.message}"
        nil
      end

      def find_epoch_card(epoch)
        return nil unless board_exists?

        target_board_id = board_id
        return nil unless target_board_id

        client.find_card_by_external_id(target_board_id, epoch.id)
      rescue Client::Error
        nil
      end

      def sync_epoch(epoch)
        # Ensure board exists before any sync operation
        ensure_board!

        card = find_epoch_card(epoch)
        card ? update_epoch_card(epoch) : create_epoch_card(epoch)
      rescue BoardNotFoundError, BoardCreationError => e
        Rails.logger.error "Kanban::BoardLink: Cannot sync epoch #{epoch.id} - #{e.message}"
        nil
      end

      def sync_all_epochs
        return { success: false, error: "Not connected" } unless connected?

        # Ensure board exists before syncing any epochs
        begin
          ensure_board!
        rescue BoardNotFoundError, BoardCreationError => e
          return { success: false, error: e.message }
        end

        results = { synced: 0, failed: 0, errors: [], board_id: board_id }

        Epoch.all.each do |epoch|
          if sync_epoch(epoch)
            results[:synced] += 1
          else
            results[:failed] += 1
            results[:errors] << epoch.id
          end
        end

        results[:success] = results[:failed].zero?
        results
      end

      # Board status - comprehensive status of the RunSpaceManager board
      def status
        board_check = check_board

        result = {
          connected: board_check[:connected],
          board_exists: board_check[:board_exists],
          board_name: BOARD_NAME,
          board_id: board_id,
          ready: board_check[:ready]
        }

        if board_check[:ready]
          result[:columns] = columns.keys
          result[:cards_count] = client.cards(board_id).size
        end

        result
      rescue Client::Error => e
        {
          connected: false,
          board_exists: false,
          board_name: BOARD_NAME,
          ready: false,
          error: e.message
        }
      end

      private

      def epoch_card_title(epoch)
        status_emoji = case epoch.status
                       when "running" then "🔄"
                       when "paused" then "⏸️"
                       when "completed" then "✅"
                       when "failed" then "❌"
                       when "stopped" then "⏹️"
                       else "📋"
                       end
        "#{status_emoji} #{epoch.name}"
      end

      def epoch_card_description(epoch)
        <<~DESC
          **Epoch ID:** #{epoch.id}
          **Status:** #{epoch.status}
          **Iteration:** #{epoch.iteration}
          **Started:** #{epoch.started_at&.strftime('%Y-%m-%d %H:%M')}

          ---

          **Prompt:**
          #{epoch.prompt&.truncate(500)}

          ---

          **Completion Marker:** `#{epoch.completion_marker}`
          **Max Iterations:** #{epoch.max_iterations || 'unlimited'}
        DESC
      end

      def epoch_priority(epoch)
        case epoch.status
        when "running" then "high"
        when "paused" then "medium"
        when "failed" then "urgent"
        else "medium"
        end
      end

      def epoch_metadata(epoch)
        {
          epoch_id: epoch.id,
          status: epoch.status,
          iteration: epoch.iteration,
          started_at: epoch.started_at&.iso8601,
          pid: epoch.pid,
          working_dir: epoch.working_dir,
          synced_at: Time.now.iso8601
        }
      end
    end
  end
end
