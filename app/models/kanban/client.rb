# frozen_string_literal: true

require "net/http"
require "json"

module Kanban
  # Client for communicating with CollaborativeKanban API
  class Client
    DEFAULT_BASE_URL = "http://localhost:3002"

    class Error < StandardError; end
    class ConnectionError < Error; end
    class NotFoundError < Error; end
    class ValidationError < Error; end

    attr_reader :base_url, :api_token

    def initialize(base_url: nil, api_token: nil)
      @base_url = base_url || ENV.fetch("KANBAN_BASE_URL", DEFAULT_BASE_URL)
      @api_token = api_token || ENV["KANBAN_API_TOKEN"]
    end

    # Board operations
    def boards
      get("/boards")
    end

    def find_board(id)
      get("/boards/#{id}")
    end

    def find_board_by_name(name)
      boards.find { |b| b["name"] == name }
    end

    def create_board(name:, level: "team", description: nil)
      post("/boards", {
        board: {
          name: name,
          level: level,
          description: description
        }
      })
    end

    def update_board(id, attributes)
      patch("/boards/#{id}", { board: attributes })
    end

    # Column operations
    def columns(board_id)
      get("/boards/#{board_id}/columns")
    end

    def find_column_by_name(board_id, name)
      board = find_board(board_id)
      board["columns"]&.find { |c| c["name"] == name }
    end

    def create_column(board_id, name:, position: nil)
      post("/boards/#{board_id}/columns", {
        column: {
          name: name,
          position: position
        }
      })
    end

    # Card operations
    def cards(board_id)
      board = find_board(board_id)
      board["cards"] || []
    end

    def find_card(board_id, card_id)
      get("/boards/#{board_id}/cards/#{card_id}")
    end

    def find_card_by_external_id(board_id, external_id)
      cards(board_id).find { |c| c["external_id"] == external_id }
    end

    def create_card(board_id, column_id:, title:, description: nil, priority: "medium",
                    card_type: "task", external_id: nil, metadata: {})
      post("/boards/#{board_id}/cards", {
        card: {
          column_id: column_id,
          title: title,
          description: description,
          priority: priority,
          card_type: card_type,
          external_id: external_id,
          metadata: metadata.to_json
        }
      })
    end

    def update_card(board_id, card_id, attributes)
      patch("/boards/#{board_id}/cards/#{card_id}", { card: attributes })
    end

    def move_card(board_id, card_id, column_id:, position: 0)
      patch("/boards/#{board_id}/cards/#{card_id}/move", {
        column_id: column_id,
        position: position
      })
    end

    def delete_card(board_id, card_id)
      delete("/boards/#{board_id}/cards/#{card_id}")
    end

    # Health check
    def healthy?
      response = get("/up")
      true
    rescue StandardError
      false
    end

    private

    def get(path)
      request(:get, path)
    end

    def post(path, body = {})
      request(:post, path, body)
    end

    def patch(path, body = {})
      request(:patch, path, body)
    end

    def delete(path)
      request(:delete, path)
    end

    def request(method, path, body = nil)
      uri = URI.join(base_url, path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 30

      request = build_request(method, uri, body)
      response = http.request(request)

      handle_response(response)
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout => e
      raise ConnectionError, "Failed to connect to CollaborativeKanban: #{e.message}"
    end

    def build_request(method, uri, body)
      request_class = {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        patch: Net::HTTP::Patch,
        delete: Net::HTTP::Delete
      }[method]

      request = request_class.new(uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{api_token}" if api_token

      request.body = body.to_json if body && [:post, :patch].include?(method)

      request
    end

    def handle_response(response)
      case response.code.to_i
      when 200..299
        return {} if response.body.nil? || response.body.empty?
        JSON.parse(response.body)
      when 404
        raise NotFoundError, "Resource not found"
      when 422
        error_body = JSON.parse(response.body) rescue {}
        raise ValidationError, error_body["errors"]&.join(", ") || "Validation failed"
      else
        raise Error, "HTTP #{response.code}: #{response.body}"
      end
    end
  end
end
