class CreateMcpServers < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_servers do |t|
      t.string :name, null: false
      t.string :repository_url, null: false
      t.string :local_path
      t.integer :port
      t.string :status, default: "unknown"
      t.datetime :last_health_check_at
      t.text :last_error
      t.string :version
      t.text :description
      t.json :metadata, default: {}

      t.timestamps
    end

    add_index :mcp_servers, :name, unique: true
    add_index :mcp_servers, :status
  end
end
