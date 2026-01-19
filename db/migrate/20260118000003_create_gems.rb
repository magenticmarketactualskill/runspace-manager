class CreateGems < ActiveRecord::Migration[8.1]
  def change
    create_table :gems do |t|
      t.string :name, null: false
      t.string :repository_url
      t.string :local_path
      t.string :version
      t.string :status, default: "unknown"
      t.text :description
      t.datetime :last_check_at
      t.text :last_error
      t.json :dependencies, default: []
      t.json :metadata, default: {}

      t.timestamps
    end

    add_index :gems, :name, unique: true
    add_index :gems, :status
  end
end
