class CreateSkills < ActiveRecord::Migration[8.1]
  def change
    create_table :skills do |t|
      t.string :name, null: false
      t.text :description
      t.references :mcp_server, null: false, foreign_key: true
      t.string :status, default: "available"
      t.integer :invocation_count, default: 0
      t.integer :error_count, default: 0
      t.float :average_latency_ms
      t.datetime :last_invoked_at
      t.text :last_error
      t.json :input_schema, default: {}
      t.json :output_schema, default: {}
      t.json :metadata, default: {}

      t.timestamps
    end

    add_index :skills, [:mcp_server_id, :name], unique: true
    add_index :skills, :status
  end
end
