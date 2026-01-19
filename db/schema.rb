# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_01_18_000003) do
  create_table "gems", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "dependencies", default: []
    t.text "description"
    t.datetime "last_check_at"
    t.text "last_error"
    t.string "local_path"
    t.json "metadata", default: {}
    t.string "name", null: false
    t.string "repository_url"
    t.string "status", default: "unknown"
    t.datetime "updated_at", null: false
    t.string "version"
    t.index ["name"], name: "index_gems_on_name", unique: true
    t.index ["status"], name: "index_gems_on_status"
  end

  create_table "mcp_servers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.text "last_error"
    t.datetime "last_health_check_at"
    t.string "local_path"
    t.json "metadata", default: {}
    t.string "name", null: false
    t.integer "port"
    t.string "repository_url", null: false
    t.string "status", default: "unknown"
    t.datetime "updated_at", null: false
    t.string "version"
    t.index ["name"], name: "index_mcp_servers_on_name", unique: true
    t.index ["status"], name: "index_mcp_servers_on_status"
  end

  create_table "skills", force: :cascade do |t|
    t.float "average_latency_ms"
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "error_count", default: 0
    t.json "input_schema", default: {}
    t.integer "invocation_count", default: 0
    t.text "last_error"
    t.datetime "last_invoked_at"
    t.integer "mcp_server_id", null: false
    t.json "metadata", default: {}
    t.string "name", null: false
    t.json "output_schema", default: {}
    t.string "status", default: "available"
    t.datetime "updated_at", null: false
    t.index ["mcp_server_id", "name"], name: "index_skills_on_mcp_server_id_and_name", unique: true
    t.index ["mcp_server_id"], name: "index_skills_on_mcp_server_id"
    t.index ["status"], name: "index_skills_on_status"
  end

  add_foreign_key "skills", "mcp_servers"
end
